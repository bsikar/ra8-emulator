//! A host folder of C6 network tapes (`--net-record`, `--net-replay`,
//! RA8EMU-560): the files behind the C6 model's tape Store (RA8EMU-1020).
const std = @import("std");

pub const Root = struct { io: std.Io, dir: std.Io.Dir };
pub const File = struct { io: std.Io, file: std.Io.File };

const heap = std.heap.page_allocator;

/// The tape folder at `path`, made first when `make` is set (recording).
pub fn open(io: std.Io, path: []const u8, make: bool) !*Root {
    const cwd = std.Io.Dir.cwd();
    if (make) try cwd.createDirPath(io, path);
    const root = try heap.create(Root);
    errdefer heap.destroy(root);
    root.* = .{ .io = io, .dir = try cwd.openDir(io, path, .{}) };
    return root;
}

pub fn release(root: *Root) void {
    root.dir.close(root.io);
    heap.destroy(root);
}

pub fn create(root: *Root, name: []const u8) !*File {
    const file = try heap.create(File);
    errdefer heap.destroy(file);
    file.* = .{ .io = root.io, .file = try root.dir.createFile(root.io, name, .{}) };
    return file;
}

pub fn append(file: *File, bytes: []const u8) !void {
    try file.file.writeStreamingAll(file.io, bytes);
}

pub fn close(file: *File) void {
    file.file.close(file.io);
    heap.destroy(file);
}

pub fn readAlloc(root: *Root, name: []const u8, allocator: std.mem.Allocator, max: usize) ![]u8 {
    return root.dir.readFileAlloc(root.io, name, allocator, .limited(max));
}

pub fn readInto(root: *Root, name: []const u8, out: []u8) ![]u8 {
    return root.dir.readFile(root.io, name, out);
}
