//! Pinned native no-replace directory movement, invoked over private pipes.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const wire = @import("wire.zig");
const Window = @import("window.zig").Window;
const name = @import("../name.zig");
const metadata = @import("../metadata.zig");
const layout = @import("../layout.zig");

/// Exit codes a watchdog ends the peer with. Neither follows a rename in
/// flight: `expired` means none was started, `drained` that one returned.
pub const exits = struct {
    pub const expired = 4;
    pub const drained = 5;
};
var window: Window = .{};

pub fn peer(allocator: std.mem.Allocator, io: std.Io) !u8 {
    if (builtin.os.tag != .windows) return error.OperationUnsupported;
    return run(allocator, io);
}

fn run(allocator: std.mem.Allocator, io: std.Io) !u8 {
    const parsed = try wire.read(wire.Request, allocator, io, .stdin(), null);
    defer parsed.deinit();
    const request = parsed.value;
    if (request.version != wire.version or !name.isId(&request.nonce)) return error.BadFrame;
    try (wire.Bounds{ .commit = request.commit_ms, .drain = request.drain_ms }).check();
    _ = try name.component(request.from);
    _ = try name.component(request.to);
    var source_root = try pinRoot(allocator, io, request.source);
    defer source_root.close(io);
    var target_root = try pinRoot(allocator, io, request.target);
    defer target_root.close(io);
    var source = try pin(allocator, io, source_root, request.from, true);
    defer source.close(io);
    const source_guard = try guard(io, source_root);
    defer source_guard.close(io);
    const same_root = (try source_root.stat(io)).inode == (try target_root.stat(io)).inode and std.mem.eql(u8, request.source.path, request.target.path);
    const target_guard = if (same_root) null else try guard(io, target_root);
    defer if (target_guard) |file| file.close(io);
    var reply: wire.Reply = .{ .nonce = request.nonce, .phase = .bound, .pid = w.GetCurrentProcessId(), .source_inode = @intCast((try source.stat(io)).inode), .source_root = @intCast((try source_root.stat(io)).inode), .target_root = @intCast((try target_root.stat(io)).inode) };
    const opened = std.Io.Timestamp.now(io, .awake);
    (try std.Thread.spawn(.{}, watch, .{ io, request.commit_ms, request.drain_ms })).detach();
    try wire.write(allocator, io, .stdout(), reply);
    const committed = try wire.read(wire.Commit, allocator, io, .stdin(), null);
    defer committed.deinit();
    if (committed.value.version != wire.version or !std.mem.eql(u8, &request.nonce, &committed.value.nonce) or !committed.value.commit) return error.Aborted;
    reply.phase = .done;
    // A COMMIT read after the window closed, or one that lost the race with
    // the watchdog, renames nothing. The clock is read here as well because
    // a peer suspended as a whole wakes with its watchdog not yet run.
    const late = opened.untilNow(io, .awake).toMilliseconds() >= request.commit_ms;
    reply.status = if (!late and window.claim()) status: {
        defer window.settle();
        break :status try rename(allocator, source, target_root, request.to);
    } else .expired;
    try wire.write(allocator, io, .stdout(), reply);
    return if (reply.status == .success) 0 else 3;
}

/// The window opens before the bound reply is written. A peer still waiting
/// for COMMIT when it closes ends here, and its pins and guards with it. A
/// peer that renamed ends once the drain has passed, reply written or not.
/// Nothing here ends a peer whose rename call has not returned.
fn watch(io: std.Io, commit_ms: u32, drain_ms: u32) void {
    io.sleep(.fromMilliseconds(commit_ms), .awake) catch {};
    if (window.expire()) std.process.exit(exits.expired);
    io.sleep(.fromMilliseconds(drain_ms), .awake) catch {};
    while (!window.settled()) io.sleep(.fromMilliseconds(tick_ms), .awake) catch {};
    std.process.exit(exits.drained);
}
const tick_ms = 50;

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
