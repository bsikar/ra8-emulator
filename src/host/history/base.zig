//! A history root: the one directory sessions live in, opened once and
//! marked as ours. Everything under it is reached through this handle by a
//! single checked name, and `owns` is the boundary every delete passes.
const std = @import("std");
const layout = @import("layout.zig");
const name = @import("name.zig");
const metadata = @import("metadata.zig");
const recovery = @import("recover.zig");

pub const Role = enum { cache, kept, runtime };
pub const Options = struct {
    native_provider: ?@import("move/provider.zig").Provider = null,
    recover: bool = true,
};

pub const gate_wait = struct {
    pub const tries = 100;
    pub const pause_ms = 10;
};

pub const Gate = struct {
    io: std.Io,
    file: std.Io.File,

    pub fn release(self: *Gate) void {
        self.file.close(self.io);
    }
};

pub const Base = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    role: Role,
    /// The root's resolved absolute path.
    path: []u8,
    native_provider: ?@import("move/provider.zig").Provider = null,

    /// The root at `path`, made and marked when it is new. `Unmarked` when
    /// the directory already holds something and is not a history root.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8, role: Role) !Base {
        return openConfigured(allocator, io, path, role, .{});
    }

    pub fn openConfigured(allocator: std.mem.Allocator, io: std.Io, path: []const u8, role: Role, options: Options) !Base {
        if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, path, layout.directory_permissions);
        return attach(allocator, io, path, role, true, options);
    }

    /// The root at `path`, which must already be one.
    pub fn existing(allocator: std.mem.Allocator, io: std.Io, path: []const u8, role: Role) !Base {
        return existingConfigured(allocator, io, path, role, .{});
    }

    pub fn existingConfigured(allocator: std.mem.Allocator, io: std.Io, path: []const u8, role: Role, options: Options) !Base {
        return attach(allocator, io, path, role, false, options);
    }

    fn attach(allocator: std.mem.Allocator, io: std.Io, path: []const u8, role: Role, adopt: bool, options: Options) !Base {
        if (!std.fs.path.isAbsolute(path)) return error.RelativePath;
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true, .follow_symlinks = false });
        errdefer dir.close(io);
        if (!marked(io, dir) and (!adopt or !try empty(io, dir))) {
            // A concurrent creator may be writing its marker while it
            // holds the gate. Wait on that existing file before deciding.
            const stat = dir.statFile(io, layout.root.gate, .{ .follow_symlinks = false }) catch return error.Unmarked;
            if (stat.kind != .file) return error.Unmarked;
        }
        const gate_file = try acquire(io, dir, .exclusive);
        var gate_open = true;
        defer if (gate_open) gate_file.close(io);
        if (!marked(io, dir)) {
            if (!adopt or !try empty(io, dir)) return error.Unmarked;
            try metadata.ensure(io, dir, layout.root.marker, markerText(role));
        }
        if (!markedAs(io, dir, role)) return error.WrongRole;
        if (role != .cache) {
            dir.access(io, layout.root.tag, .{}) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            if (tagged(io, dir)) return error.WrongRole;
        } else try metadata.ensureTag(io, dir, layout.root.tag, layout.root.tag_text);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = try dir.realPath(io, &buffer);
        var result: Base = .{ .allocator = allocator, .io = io, .dir = dir, .role = role, .path = try allocator.dupe(u8, buffer[0..len]), .native_provider = options.native_provider };
        errdefer allocator.free(result.path);
        gate_file.close(io);
        gate_open = false;
        if (role != .runtime and options.recover) try result.recoverLocked();
        return result;
    }

    pub fn close(self: *Base) void {
        self.dir.close(self.io);
        self.allocator.free(self.path);
    }

    /// Hold the root's gate: shared to publish or reopen a session,
    /// exclusive to decide a deletion. `GateBusy` after about a second.
    pub fn gate(self: *const Base, how: std.Io.File.Lock) !Gate {
        try self.checkMarked();
        return .{ .io = self.io, .file = try acquire(self.io, self.dir, how) };
    }

    /// Pass only when `entry` is a real directory directly inside this
    /// root: one checked component, not a link or a junction, resolving to
    /// exactly the root's path plus that name.
    pub fn owns(self: *const Base, entry: []const u8) error{ BadName, NotFound, OutsideRoot }!void {
        self.checkMarked() catch return error.OutsideRoot;
        _ = try name.component(entry);
        const stat = self.dir.statFile(self.io, entry, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return error.NotFound,
            else => return error.OutsideRoot,
        };
        if (stat.kind != .directory) return error.OutsideRoot;
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = self.dir.realPathFile(self.io, entry, &buffer) catch return error.OutsideRoot;
        if (!self.directChild(buffer[0..len], entry)) return error.OutsideRoot;
    }

    /// True when the absolute path `real` is `entry` directly in this root.
    pub fn directChild(self: *const Base, real: []const u8, entry: []const u8) bool {
        if (real.len != self.path.len + 1 + entry.len) return false;
        if (!std.mem.startsWith(u8, real, self.path) or real[self.path.len] != std.fs.path.sep) return false;
        return std.mem.eql(u8, real[self.path.len + 1 ..], entry);
    }

    /// The absolute path of `entry` in this root, owned by the caller.
    pub fn pathOf(self: *const Base, allocator: std.mem.Allocator, entry: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ self.path, std.fs.path.sep, try name.component(entry) });
    }

    pub fn checkMarked(self: *const Base) error{Unmarked}!void {
        if (!markedAs(self.io, self.dir, self.role)) return error.Unmarked;
    }

    /// Repair a process killed while its lease was parked. Never touch a
    /// held lease or an entry belonging to another host. No recursive delete.
    pub fn recover(self: *const Base) !void {
        try self.recoverLocked();
    }

    pub fn recoverReport(self: *const Base, observer: ?recovery.Observer) !recovery.Report {
        return recovery.runReport(self, observer);
    }

    /// Put right what a killed process left, with the exclusive gate held.
    fn recoverLocked(self: *const Base) !void {
        return recovery.run(self);
    }
};

fn acquire(io: std.Io, dir: std.Io.Dir, how: std.Io.File.Lock) !std.Io.File {
    try metadata.ensure(io, dir, layout.root.gate, "");
    const file = try metadata.empty(io, dir, layout.root.gate, .read_write);
    errdefer file.close(io);
    for (0..gate_wait.tries) |_| {
        if (try file.tryLock(io, how)) return file;
        try std.Io.sleep(io, .fromMilliseconds(gate_wait.pause_ms), .awake);
    }
    return error.GateBusy;
}

fn marked(io: std.Io, dir: std.Io.Dir) bool {
    return markedAs(io, dir, .cache) or markedAs(io, dir, .kept) or markedAs(io, dir, .runtime);
}

fn markedAs(io: std.Io, dir: std.Io.Dir, role: Role) bool {
    metadata.expect(io, dir, layout.root.marker, markerText(role)) catch return false;
    return true;
}

fn markerText(role: Role) []const u8 {
    return switch (role) {
        .cache => layout.root.marker_text,
        .kept => layout.root.kept_marker_text,
        .runtime => layout.root.runtime_marker_text,
    };
}

fn empty(io: std.Io, dir: std.Io.Dir) !bool {
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, layout.root.gate)) return false;
    }
    return true;
}

fn tagged(io: std.Io, dir: std.Io.Dir) bool {
    _ = dir.statFile(io, layout.root.tag, .{ .follow_symlinks = false }) catch return false;
    return true;
}
