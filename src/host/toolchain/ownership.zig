//! Cache objects belong to this user and grant mutation only to trusted principals.
const builtin = @import("builtin");
const std = @import("std");

const w = std.os.windows;

pub fn directory(io: std.Io, dir: std.Io.Dir) !void {
    if ((try dir.stat(io)).kind != .directory) return error.UnsafeCacheOwnership;
    try check(dir.handle, false);
}

/// Parents must not let another principal rename the admitted cache subtree.
pub fn ancestor(io: std.Io, dir: std.Io.Dir) !void {
    if ((try dir.stat(io)).kind != .directory) return error.UnsafeCacheOwnership;
    try check(dir.handle, true);
}

pub fn file(io: std.Io, opened: std.Io.File) !void {
    if ((try opened.stat(io)).kind != .file) return error.UnsafeCacheOwnership;
    try check(opened.handle, false);
}

/// Only for an empty directory the caller has just created exclusively.
/// Existing directories are validated, never repaired by this helper.
pub fn makePrivate(io: std.Io, dir: std.Io.Dir) !void {
    if (builtin.os.tag == .windows) {
        try Windows.private(dir.handle);
    } else {
        // Linux opens non-iterable directories with O_PATH, which fchmod
        // cannot use. Reopen the pinned directory with ordinary access.
        const writable = try dir.openDir(io, ".", .{ .iterate = true, .follow_symlinks = false });
        defer writable.close(io);
        try writable.setPermissions(io, .fromMode(0o700));
    }
    try directory(io, dir);
}

/// Only immediately after exclusive file creation under a protected parent.
/// Preserve the inherited DACL, but replace an elevated token's default group
/// owner with its user SID so future admission remains strictly user-owned.
pub fn makeFilePrivate(io: std.Io, parent: std.Io.Dir, name: []const u8, opened: std.Io.File) !void {
    if (builtin.os.tag != .windows) {
        try file(io, opened);
        return;
    }
    const handle = try Windows.editFile(parent.handle, name);
    defer _ = w.ntdll.NtClose(handle);
    const secured: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
    const actual = try secured.stat(io);
    const expected = try opened.stat(io);
    if (actual.inode != expected.inode or actual.kind != .file or actual.nlink != 1) {
        return error.UnsafeCacheOwnership;
    }
    try Windows.ensureFilePrivate(handle);
}

fn check(handle: std.Io.File.Handle, parent: bool) !void {
    switch (builtin.os.tag) {
        .windows => try Windows.check(handle, parent),
        .linux => {
            const linux = std.os.linux;
            var stat: linux.Statx = undefined;
            const request: linux.STATX = .{ .UID = true, .MODE = true };
            if (linux.errno(linux.statx(handle, "", linux.AT.EMPTY_PATH, request, &stat)) != .SUCCESS) {
                return error.CacheOwnershipUnavailable;
            }
            if (!stat.mask.UID or !stat.mask.MODE) return error.CacheOwnershipUnavailable;
            try posixPolicy(stat.uid, linux.geteuid(), stat.mode, parent);
        },
        else => {
            var stat: std.posix.Stat = undefined;
            if (std.c.fstat(handle, &stat) != 0) return error.CacheOwnershipUnavailable;
            try posixPolicy(stat.uid, std.c.geteuid(), stat.mode, parent);
        },
    }
}

/// The pure policy also lets tests exercise a different owner without privilege.
pub fn posix(owner: u32, current: u32, mode: u32) !void {
    try posixPolicy(owner, current, mode, false);
}

pub fn posixAncestor(owner: u32, current: u32, mode: u32) !void {
    try posixPolicy(owner, current, mode, true);
}

fn posixPolicy(owner: u32, current: u32, mode: u32, parent: bool) !void {
    if (parent) {
        if (owner != 0 and owner != current) return error.UnsafeCacheOwnership;
        // Sticky directories permit additions but protect entries owned by us.
        // An unrelated sticky-directory owner could still rename our entry.
        if (mode & 0o1000 != 0) return;
    } else if (owner != current) return error.UnsafeCacheOwnership;
    if (mode & 0o022 != 0) return error.UnsafeCacheOwnership;
}

/// Narrow Win32 security boundary; all decisions use the already-open object.
pub const Windows = struct {
    const Acl = extern struct { revision: u8, reserved: u8, size: u16, count: u16, reserved2: u16 };
    const Header = extern struct { kind: u8, flags: u8, size: u16 };
    const Allowed = extern struct { header: Header, mask: u32, sid_start: u32 };
    const User = extern struct { sid: *anyopaque, attributes: u32 };
    const Token = struct {
        bytes: [256]u8 align(@alignOf(User)) = undefined,
        sid_offset: usize = 0,

        fn init() !Token {
            var handle: w.HANDLE = undefined;
            if (!OpenProcessToken(w.GetCurrentProcess(), 8, &handle).toBool()) return error.CacheOwnershipUnavailable;
            defer _ = w.ntdll.NtClose(handle);
            var self: Token = .{};
            var needed: u32 = 0;
            if (!GetTokenInformation(handle, 1, &self.bytes, self.bytes.len, &needed).toBool()) {
                return error.CacheOwnershipUnavailable;
            }
            const returned: *const User = @ptrCast(&self.bytes);
            self.sid_offset = @intFromPtr(returned.sid) - @intFromPtr(&self.bytes);
            if (self.sid_offset + 8 > self.bytes.len) return error.CacheOwnershipUnavailable;
            return self;
        }

        fn sid(self: *Token) *anyopaque {
            // TOKEN_USER embeds a pointer into its buffer: reconstruct the SID
            // offset after returning/copying the value rather than keep that pointer.
            return @ptrCast(&self.bytes[self.sid_offset]);
        }
    };

    const Descriptor = struct {
        owner: ?*anyopaque = null,
        acl: ?*Acl = null,
        allocation: ?*anyopaque = null,

        fn init(handle: w.HANDLE) !Descriptor {
            var self: Descriptor = .{};
            if (GetSecurityInfo(handle, 1, 5, &self.owner, null, &self.acl, null, &self.allocation) != 0) {
                return error.CacheOwnershipUnavailable;
            }
            return self;
        }

        fn deinit(self: Descriptor) void {
            _ = LocalFree(self.allocation);
        }
    };

    var user_state: std.atomic.Value(u8) = .init(0);
    var user_token: Token = .{};

    fn processUser() !*anyopaque {
        while (user_state.load(.acquire) != 2) {
            if (user_state.cmpxchgWeak(0, 1, .acq_rel, .acquire) == null) {
                errdefer user_state.store(0, .release);
                user_token = try Token.init();
                user_state.store(2, .release);
                return user_token.sid();
            }
            std.atomic.spinLoopHint();
        }
        return user_token.sid();
    }

    fn check(handle: w.HANDLE, parent: bool) !void {
        const user_sid = try processUser();
        const descriptor = try Descriptor.init(handle);
        defer descriptor.deinit();
        try checkDescriptor(handle, descriptor, user_sid, parent);
    }

    fn checkDescriptor(handle: w.HANDLE, descriptor: Descriptor, user_sid: *anyopaque, parent: bool) !void {
        const owner = descriptor.owner orelse return error.UnsafeCacheOwnership;
        if (!trusted(owner, user_sid, parent)) return ownerFailure(handle, owner, user_sid, parent);
        const acl = descriptor.acl orelse return error.UnsafeCacheOwnership;
        if (!IsValidAcl(acl).toBool()) return error.UnsafeCacheOwnership;
        var index: u32 = 0;
        while (index < acl.count) : (index += 1) {
            var entry: ?*anyopaque = null;
            if (!GetAce(acl, index, &entry).toBool()) return error.UnsafeCacheOwnership;
            try ace(entry orelse return error.UnsafeCacheOwnership, user_sid, parent);
        }
    }

    fn ensureFilePrivate(handle: w.HANDLE) !void {
        const user_sid = try processUser();
        const descriptor = try Descriptor.init(handle);
        const owner = descriptor.owner orelse {
            descriptor.deinit();
            return error.UnsafeCacheOwnership;
        };
        if (EqualSid(owner, user_sid).toBool()) {
            defer descriptor.deinit();
            return checkDescriptor(handle, descriptor, user_sid, false);
        }
        descriptor.deinit();
        if (SetSecurityInfo(handle, 1, 1, user_sid, null, null, null) != 0) {
            return error.CacheOwnershipUnavailable;
        }
        return Windows.check(handle, false);
    }

    fn ownerFailure(handle: w.HANDLE, owner: *anyopaque, user: *anyopaque, parent: bool) error{UnsafeCacheOwnership} {
        var owner_text: ?[*:0]u8 = null;
        var user_text: ?[*:0]u8 = null;
        _ = ConvertSidToStringSidA(owner, &owner_text);
        defer if (owner_text) |text| {
            _ = LocalFree(@ptrCast(text));
        };
        _ = ConvertSidToStringSidA(user, &user_text);
        defer if (user_text) |text| {
            _ = LocalFree(@ptrCast(text));
        };
        var wide: [4096]u16 = undefined;
        const length = GetFinalPathNameByHandleW(handle, &wide, wide.len, 0);
        var utf8: [12_288]u8 = undefined;
        const path = if (length > 0 and length < wide.len)
            utf8[0..std.unicode.wtf16LeToWtf8(&utf8, wide[0..length])]
        else
            "<unavailable>";
        std.log.warn("cache {s} owner refused: path={s}, owner={s}, process-user={s}", .{
            if (parent) "ancestor" else "object",
            path,
            if (owner_text) |text| std.mem.span(text) else "<unavailable>",
            if (user_text) |text| std.mem.span(text) else "<unavailable>",
        });
        return error.UnsafeCacheOwnership;
    }

    fn ace(entry: *anyopaque, user: *anyopaque, parent: bool) !void {
        const header: *const Header = @ptrCast(@alignCast(entry));
        // Inherit-only grants affect children, which are checked independently.
        if (parent and header.flags & 8 != 0) return;
        if (header.kind == 1) return; // A deny ACE cannot grant access.
        if (header.kind != 0 or header.size < @sizeOf(Allowed)) return error.UnsafeCacheOwnership;
        const allowed: *const Allowed = @ptrCast(@alignCast(entry));
        // Everything outside read, execute, READ_CONTROL and SYNCHRONIZE can
        // mutate this object or authorize another writer (including generic rights).
        const read_only: u32 = 0x80000000 | 0x20000000 | 0x001200A9;
        // An ancestor may allow creating another subdirectory. It must never
        // allow modifying this parent or deleting/replacing an existing child.
        const harmless = read_only | @as(u32, if (parent) 4 else 0);
        if (allowed.mask & ~harmless == 0) return;
        const sid: *anyopaque = @ptrCast(@constCast(&allowed.sid_start));
        if (!IsValidSid(sid).toBool() or GetLengthSid(sid) > header.size - 8) return error.UnsafeCacheOwnership;
        if (trusted(sid, user, true)) return;
        return error.UnsafeCacheOwnership;
    }

    const ServiceSid = extern struct {
        revision: u8 = 1,
        sub_authority_count: u8 = 6,
        authority: [6]u8 = .{ 0, 0, 0, 0, 0, 5 },
        sub_authorities: [6]u32,
    };
    const trusted_installer: ServiceSid = .{
        .sub_authorities = .{ 80, 956008885, 3418522649, 1831038044, 1853292631, 2271478464 },
    };

    fn trusted(sid: *anyopaque, user: *anyopaque, administrators: bool) bool {
        if (EqualSid(sid, user).toBool()) return true;
        if (!administrators) return false;
        return IsWellKnownSid(sid, 22).toBool() or
            IsWellKnownSid(sid, 26).toBool() or
            EqualSid(sid, @ptrCast(@constCast(&trusted_installer))).toBool();
    }

    fn private(handle: w.HANDLE) !void {
        var user = try Token.init();
        const writable = try editDirectory(handle, true);
        defer _ = w.ntdll.NtClose(writable);
        var buffer: [512]u8 align(4) = undefined;
        const acl: *Acl = @ptrCast(&buffer);
        if (!InitializeAcl(acl, buffer.len, 2).toBool()) return error.CacheOwnershipUnavailable;
        try grant(acl, user.sid());
        var system: [68]u8 align(4) = undefined;
        var admin: [68]u8 align(4) = undefined;
        try grant(acl, try known(22, &system));
        try grant(acl, try known(26, &admin));
        // Protect this new directory from inherited grants. Child objects inherit
        // these three ACEs. SetSecurityInfo propagates, so never use on old trees.
        if (SetSecurityInfo(writable, 1, 0x80000005, user.sid(), null, acl, null) != 0) {
            return error.CacheOwnershipUnavailable;
        }
    }

    /// Reopen the pinned object, including after rename. Native NT paths do
    /// not normalize ".": an empty relative name reopens RootDirectory itself.
    /// This is also the reopen operation used by Go's Windows openat backend.
    pub fn editDirectory(handle: w.HANDLE, change_owner: bool) !w.HANDLE {
        var name: w.UNICODE_STRING = .empty;
        const attributes: w.OBJECT.ATTRIBUTES = .{
            .RootDirectory = handle,
            .ObjectName = &name,
            .Attributes = .{ .DONT_REPARSE = true },
        };
        var result: w.HANDLE = undefined;
        var status_block: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtOpenFile(
            &result,
            .{ .STANDARD = .{
                .RIGHTS = .{ .READ_CONTROL = true, .WRITE_DAC = true, .WRITE_OWNER = change_owner },
                .SYNCHRONIZE = true,
            } },
            &attributes,
            &status_block,
            .VALID_FLAGS,
            .{ .DIRECTORY_FILE = true, .OPEN_REPARSE_POINT = true, .IO = .SYNCHRONOUS_NONALERT },
        );
        if (status != .SUCCESS) return ntFailure("directory reopen", status);
        return result;
    }

    fn editFile(parent: w.HANDLE, path: []const u8) !w.HANDLE {
        var buffer: [4096]u16 = undefined;
        if (path.len > buffer.len) return error.UnsafeCacheOwnership;
        const length = try std.unicode.wtf8ToWtf16Le(&buffer, path);
        var name = w.UNICODE_STRING.init(buffer[0..length]);
        const attributes: w.OBJECT.ATTRIBUTES = .{
            .RootDirectory = parent,
            .ObjectName = &name,
            .Attributes = .{ .DONT_REPARSE = true },
        };
        var result: w.HANDLE = undefined;
        var status_block: w.IO_STATUS_BLOCK = undefined;
        const status = w.ntdll.NtCreateFile(
            &result,
            .{
                .SPECIFIC = .{ .FILE = .{ .READ_ATTRIBUTES = true } },
                .STANDARD = .{
                    .RIGHTS = .{ .READ_CONTROL = true, .WRITE_OWNER = true },
                    .SYNCHRONIZE = true,
                },
            },
            &attributes,
            &status_block,
            null,
            .{ .NORMAL = true },
            .VALID_FLAGS,
            .OPEN,
            .{ .NON_DIRECTORY_FILE = true, .OPEN_REPARSE_POINT = true, .IO = .SYNCHRONOUS_NONALERT },
            null,
            0,
        );
        if (status != .SUCCESS) return ntFailure("new file security open", status);
        return result;
    }

    fn ntFailure(operation: []const u8, status: w.NTSTATUS) error{CacheOwnershipUnavailable} {
        std.log.err("cache {s} failed with NTSTATUS 0x{X:0>8}", .{ operation, @backingInt(status) });
        return error.CacheOwnershipUnavailable;
    }

    fn known(kind: u32, buffer: *[68]u8) !*anyopaque {
        var size: u32 = buffer.len;
        if (!CreateWellKnownSid(kind, null, buffer, &size).toBool()) return error.CacheOwnershipUnavailable;
        return buffer;
    }

    fn grant(acl: *Acl, sid: *anyopaque) !void {
        if (!AddAccessAllowedAceEx(acl, 2, 3, 0x001F01FF, sid).toBool()) return error.CacheOwnershipUnavailable;
    }

    extern "advapi32" fn OpenProcessToken(w.HANDLE, u32, *w.HANDLE) callconv(.winapi) w.BOOL;
    extern "advapi32" fn GetTokenInformation(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(.winapi) w.BOOL;
    extern "advapi32" fn GetSecurityInfo(
        w.HANDLE,
        u32,
        u32,
        *?*anyopaque,
        ?*?*anyopaque,
        *?*Acl,
        ?*?*Acl,
        *?*anyopaque,
    ) callconv(.winapi) u32;
    extern "advapi32" fn SetSecurityInfo(
        w.HANDLE,
        u32,
        u32,
        ?*anyopaque,
        ?*anyopaque,
        ?*Acl,
        ?*Acl,
    ) callconv(.winapi) u32;
    extern "advapi32" fn EqualSid(*anyopaque, *anyopaque) callconv(.winapi) w.BOOL;
    extern "advapi32" fn IsValidSid(*anyopaque) callconv(.winapi) w.BOOL;
    extern "advapi32" fn GetLengthSid(*anyopaque) callconv(.winapi) u32;
    extern "advapi32" fn IsWellKnownSid(*anyopaque, u32) callconv(.winapi) w.BOOL;
    extern "advapi32" fn CreateWellKnownSid(u32, ?*anyopaque, *anyopaque, *u32) callconv(.winapi) w.BOOL;
    extern "advapi32" fn IsValidAcl(*Acl) callconv(.winapi) w.BOOL;
    extern "advapi32" fn GetAce(*Acl, u32, *?*anyopaque) callconv(.winapi) w.BOOL;
    extern "advapi32" fn InitializeAcl(*Acl, u32, u32) callconv(.winapi) w.BOOL;
    extern "advapi32" fn AddAccessAllowedAceEx(*Acl, u32, u32, u32, *anyopaque) callconv(.winapi) w.BOOL;
    extern "advapi32" fn ConvertSidToStringSidA(*anyopaque, *?[*:0]u8) callconv(.winapi) w.BOOL;
    extern "kernel32" fn GetFinalPathNameByHandleW(w.HANDLE, [*]u16, u32, u32) callconv(.winapi) u32;
    extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
};
