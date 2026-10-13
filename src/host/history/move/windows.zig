//! Pinned native no-replace directory movement, invoked over private pipes.
const std = @import("std");
const builtin = @import("builtin");
const w = std.os.windows;
const wire = @import("wire.zig");
const name = @import("../name.zig");
const metadata = @import("../metadata.zig");
const layout = @import("../layout.zig");

pub fn peer(allocator: std.mem.Allocator, io: std.Io) !u8 {
    if (builtin.os.tag != .windows) return error.OperationUnsupported;
    return run(allocator, io);
}

fn run(allocator: std.mem.Allocator, io: std.Io) !u8 {
    const parsed = try wire.read(wire.Request, allocator, io, .stdin());
    defer parsed.deinit();
    const request = parsed.value;
    if (request.version != wire.version or !name.isId(&request.nonce)) return error.BadFrame;
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
    try wire.write(allocator, io, .stdout(), reply);
    const committed = try wire.read(wire.Commit, allocator, io, .stdin());
    defer committed.deinit();
    if (committed.value.version != wire.version or !std.mem.eql(u8, &request.nonce, &committed.value.nonce) or !committed.value.commit) return error.Aborted;
    reply.phase = .done;
    reply.status = try rename(allocator, source, target_root, request.to);
    try wire.write(allocator, io, .stdout(), reply);
    return if (reply.status == .success) 0 else 3;
}

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
