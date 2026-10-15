//! Pinned native no-replace directory movement, invoked over private pipes.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const wire = @import("wire.zig");
const verify = @import("verify.zig");
const Window = @import("window.zig").Window;
const name = @import("../name.zig");
const metadata = @import("../metadata.zig");
const layout = @import("../layout.zig");
const intent = @import("intent.zig");

extern "kernel32" fn GetProcessTimes(w.HANDLE, *w.FILETIME, *w.FILETIME, *w.FILETIME, *w.FILETIME) callconv(.winapi) w.BOOL;

/// Normal reply exits and watchdog exits. `unready` and `expired` mean no
/// rename started and `drained` that one returned. `unsettled` is the only
/// exit with a rename in flight: the call had not returned by commit plus
/// drain, and whether it renamed is whatever the directories show once the
/// process is gone.
pub const exits = struct {
    pub const success = 0;
    pub const rejected = 3;
    pub const expired = 4;
    pub const drained = 5;
    pub const unready = 6;
    pub const unsettled = 7;
};
var window: Window = .{};
/// The caller's ready bound once its request is read; until then the
/// longest any caller may configure.
var ready_ms: std.atomic.Value(u32) = .init(wire.Bounds.limit);
/// Written by `run` before it opens the window, read by the watchdog after.
var opened: std.Io.Timestamp = undefined;
var commit_ms: u32 = 0;
var drain_ms: u32 = 0;

pub fn peer(allocator: std.mem.Allocator, io: std.Io) !u8 {
    if (builtin.os.tag != .windows) return error.OperationUnsupported;
    return run(allocator, io);
}

fn run(allocator: std.mem.Allocator, io: std.Io) !u8 {
    (try std.Thread.spawn(.{}, watch, .{io})).detach();
    const parsed = try wire.read(wire.Request, allocator, io, .stdin(), null);
    defer parsed.deinit();
    const request = parsed.value;
    try verify.frame(request);
    ready_ms.store(request.ready_ms, .seq_cst);
    var pins = try Pins.take(allocator, io, request);
    defer pins.close(io);
    var reply: wire.Reply = .{ .version = wire.version, .nonce = request.nonce, .operation = request.operation, .proof = try prove(allocator, io, pins, request), .phase = .bound, .pid = w.GetCurrentProcessId(), .birth = try birth(), .source_inode = @intCast((try pins.source.stat(io)).inode), .source_root = @intCast((try pins.source_root.stat(io)).inode), .target_root = @intCast((try pins.target_root.stat(io)).inode) };
    commit_ms = request.commit_ms;
    drain_ms = request.drain_ms;
    opened = std.Io.Timestamp.now(io, .awake);
    if (!window.open()) park(io);
    try wire.write(allocator, io, .stdout(), reply);
    const committed = try wire.read(wire.Commit, allocator, io, .stdin(), null);
    defer committed.deinit();
    try verify.commit(request, committed.value);
    reply.phase = .done;
    // A COMMIT read after the window closed, or one that lost the race with
    // the watchdog, renames nothing. The clock is read here as well because
    // a peer suspended as a whole wakes with its watchdog not yet run.
    const late = opened.untilNow(io, .awake).toMilliseconds() >= request.commit_ms;
    reply.status = if (!late and window.claim()) status: {
        const renamed = rename(allocator, pins.source, pins.target_root, request.to);
        if (!window.settle()) park(io);
        break :status try renamed;
    } else .expired;
    try wire.write(allocator, io, .stdout(), reply);
    return if (reply.status == .success) exits.success else exits.rejected;
}

/// The intent the request names, read through this peer's own pins. The
/// request must name exactly it: its nonce and names, both roots as the
/// intent recorded them, and the digests of the bytes read here.
fn prove(allocator: std.mem.Allocator, io: std.Io, pins: Pins, request: wire.Request) !wire.Proof {
    const proof = try intent.boundProof(allocator, io, pins.source_root, pins.source, request.from);
    defer proof.deinit();
    const record = proof.record.value;
    const source = try wire.windowsPath(allocator, record.from_path);
    defer allocator.free(source);
    const target = try wire.windowsPath(allocator, record.to_path);
    defer allocator.free(target);
    try verify.bound(request, .{ .nonce = record.nonce, .from = record.from, .to = record.to, .source = source, .target = target, .proof = proof.digest });
    return proof.digest;
}

/// The creation time of this process, reported beside its PID so the two
/// replies of one exchange can be matched. Never a signalling authority.
fn birth() !u64 {
    var created: w.FILETIME = undefined;
    var exited: w.FILETIME = undefined;
    var kernel: w.FILETIME = undefined;
    var user: w.FILETIME = undefined;
    if (!GetProcessTimes(w.GetCurrentProcess(), &created, &exited, &kernel, &user).toBool()) return error.ProcessIdentityUnavailable;
    const value = (@as(u64, created.dwHighDateTime) << 32) | created.dwLowDateTime;
    if (value == 0) return error.ProcessIdentityUnavailable;
    return value;
}

/// The watchdog starts with the process and owns every way the peer ends
/// itself. A peer not bound within the caller's ready bound ends here, and
/// so does one still waiting for COMMIT when its window closes, and its pins
/// and guards with it. A peer that renamed ends once the drain has passed,
/// reply written or not. A peer whose rename call has not returned by then
/// is ended as well: a thread stalled short of the call never makes it, and
/// a call the kernel can cancel is cancelled. A call the kernel will not
/// cancel keeps the process, its guards and so its proxy's flocks until it
/// returns; nothing in user mode ends that sooner.
fn watch(io: std.Io) void {
    const born = std.Io.Timestamp.now(io, .awake);
    while (true) : (io.sleep(.fromMilliseconds(tick_ms), .awake) catch {}) switch (window.state.load(.seq_cst)) {
        .starting => if (born.untilNow(io, .awake).toMilliseconds() >= ready_ms.load(.seq_cst) and window.unready()) end(exits.unready),
        .waiting => if (age(io) >= commit_ms and window.expire()) end(exits.expired),
        .committing => if (age(io) >= @as(u64, commit_ms) + drain_ms and window.abandon()) end(exits.unsettled),
        .settled => if (age(io) >= @as(u64, commit_ms) + drain_ms) end(exits.drained),
        .expired, .abandoned => {},
    };
}
const tick_ms = 10;

fn age(io: std.Io) i64 {
    return opened.untilNow(io, .awake).toMilliseconds();
}

/// End the whole process from the watchdog without running anything that
/// could wait on a stalled thread.
fn end(code: u8) noreturn {
    _ = w.ntdll.NtTerminateProcess(w.GetCurrentProcess(), @fromBackingInt(@intCast(code)));
    std.process.exit(code);
}

/// The watchdog won this stage and is ending the process.
fn park(io: std.Io) noreturn {
    while (true) io.sleep(.fromMilliseconds(tick_ms), .awake) catch {};
}

/// Both roots, the source entry and the root marker guards, held for the
/// whole exchange.
const Pins = struct {
    source_root: std.Io.Dir,
    target_root: std.Io.Dir,
    source: std.Io.Dir,
    source_guard: std.Io.File,
    target_guard: ?std.Io.File,

    fn take(allocator: std.mem.Allocator, io: std.Io, request: wire.Request) !Pins {
        var source_root = try pinRoot(allocator, io, request.source);
        errdefer source_root.close(io);
        var target_root = try pinRoot(allocator, io, request.target);
        errdefer target_root.close(io);
        var source = try pin(allocator, io, source_root, request.from, true);
        errdefer source.close(io);
        const source_guard = try guard(io, source_root);
        errdefer source_guard.close(io);
        const same_root = (try source_root.stat(io)).inode == (try target_root.stat(io)).inode and std.mem.eql(u8, request.source.path, request.target.path);
        const target_guard = if (same_root) null else try guard(io, target_root);
        return .{ .source_root = source_root, .target_root = target_root, .source = source, .source_guard = source_guard, .target_guard = target_guard };
    }

    fn close(self: *Pins, io: std.Io) void {
        if (self.target_guard) |file| file.close(io);
        self.source_guard.close(io);
        self.source.close(io);
        self.target_root.close(io);
        self.source_root.close(io);
    }
};

fn pinRoot(allocator: std.mem.Allocator, io: std.Io, root: wire.Root) !std.Io.Dir {
    if (root.path.len < 3 or !std.ascii.isAlphabetic(root.path[0]) or root.path[1] != ':' or root.path[2] != '\\') return error.UnsupportedRoot;
    if (!std.mem.eql(u8, root.marker, layout.root.marker_text) and !std.mem.eql(u8, root.marker, layout.root.kept_marker_text)) return error.Unmarked;
    const path = try std.fmt.allocPrint(allocator, "\\??\\{s}", .{root.path});
    defer allocator.free(path);
    var result = try pin(allocator, io, null, path, false);
    errdefer result.close(io);
    try metadata.expect(io, result, layout.root.marker, root.marker);
    return result;
}

fn pin(allocator: std.mem.Allocator, io: std.Io, root: ?std.Io.Dir, path: []const u8, deleting: bool) !std.Io.Dir {
    const utf16 = try std.unicode.wtf8ToWtf16LeAlloc(allocator, path);
    defer allocator.free(utf16);
    var unicode = w.UNICODE_STRING.init(utf16);
    const attributes: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = if (root) |dir| dir.handle else null, .ObjectName = &unicode, .Attributes = .{ .DONT_REPARSE = true } };
    var handle: w.HANDLE = undefined;
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtCreateFile(&handle, .{ .SPECIFIC = .{ .FILE_DIRECTORY = .{ .LIST = true, .READ_ATTRIBUTES = true, .TRAVERSE = true } }, .STANDARD = .{ .RIGHTS = .{ .DELETE = deleting }, .SYNCHRONIZE = true } }, &attributes, &iosb, null, .{ .NORMAL = true }, .{ .READ = true, .WRITE = true }, .OPEN, .{ .DIRECTORY_FILE = true, .OPEN_REPARSE_POINT = true, .IO = .SYNCHRONOUS_NONALERT }, null, 0);
    if (status != .SUCCESS) return error.NativePinFailed;
    var result: std.Io.Dir = .{ .handle = handle };
    errdefer result.close(io);
    if ((try result.stat(io)).kind != .directory) return error.OutsideRoot;
    return result;
}

/// Root markers contain bytes, so a surviving peer blocks all Base marker
/// checks even if its Linux proxy loses the inherited flock descriptors.
fn guard(io: std.Io, root: std.Io.Dir) !std.Io.File {
    const file = try metadata.open(io, root, layout.root.marker, .read_write);
    errdefer file.close(io);
    if (!try file.tryLock(io, .exclusive)) return error.Locked;
    return file;
}

fn rename(allocator: std.mem.Allocator, source: std.Io.Dir, target: std.Io.Dir, leaf: []const u8) !wire.Status {
    const utf16 = try std.unicode.wtf8ToWtf16LeAlloc(allocator, leaf);
    defer allocator.free(utf16);
    var information: w.FILE.RENAME_INFORMATION = .init(.{ .Flags = .{}, .RootDirectory = target.handle, .FileName = utf16 });
    const bytes = information.toBuffer();
    var iosb: w.IO_STATUS_BLOCK = undefined;
    const status = w.ntdll.NtSetInformationFile(source.handle, &iosb, bytes.ptr, @intCast(bytes.len), .RenameEx);
    return switch (status) {
        .SUCCESS => .success,
        .OBJECT_NAME_COLLISION, .DIRECTORY_NOT_EMPTY => .collision,
        .NOT_SAME_DEVICE => .cross_device,
        else => .refused,
    };
}
