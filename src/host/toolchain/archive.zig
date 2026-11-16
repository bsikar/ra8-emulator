//! Verify complete pinned archive bytes before parsing or materializing files.
const std = @import("std");

const artifacts = @import("artifact.zig");
const digest = @import("digest.zig");
const Tree = @import("tree.zig").Tree;

pub fn verify(io: std.Io, file: std.Io.File, artifact: artifacts.Artifact) !void {
    if ((try file.stat(io)).size != artifact.archive_bytes) return error.ArchiveSizeMismatch;
    if (!std.mem.eql(u8, &try digest.file(io, file, artifact.archive_bytes), artifact.sha256)) {
        return error.ArchiveHashMismatch;
    }
}

pub fn walk(file: std.Io.File, artifact: artifacts.Artifact, tree: *Tree) !void {
    try verify(tree.io, file, artifact);
    var buffer: [65536]u8 = undefined;
    var reader = file.reader(tree.io, &buffer);
    if (std.mem.endsWith(u8, artifact.url, ".zip")) {
        var cd_buffer: [65536]u8 = undefined;
        var cd = file.reader(tree.io, &cd_buffer);
        try zip(&cd, &reader, tree);
    } else {
        var decompress = try std.compress.xz.Decompress.init(&reader.interface, tree.allocator, &.{});
        defer decompress.deinit();
        try tar(&decompress.reader, tree);
        var tail: [4096]u8 = undefined;
        while (try decompress.reader.readSliceShort(&tail) != 0) {}
    }
    try tree.finish();
}

const TarSource = struct {
    iterator: *std.tar.Iterator,
    file: std.tar.Iterator.File,

    pub fn writeTo(self: TarSource, writer: *std.Io.Writer) !void {
        try self.iterator.streamRemaining(self.file, writer);
    }
};

fn tar(reader: *std.Io.Reader, tree: *Tree) !void {
    var names: [4096]u8 = undefined;
    var links: [4096]u8 = undefined;
    var iterator = std.tar.Iterator.init(reader, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    while (try iterator.next()) |entry| {
        if (entry.kind == .sym_link) return error.ArchiveLinkRefused;
        try tree.accept(.{
            .name = entry.name,
            .size = entry.size,
            .mode = entry.mode,
            .kind = if (entry.kind == .file) .file else .directory,
        }, TarSource{ .iterator = &iterator, .file = entry });
    }
}

const ZipSource = struct {
    reader: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,

    pub fn writeTo(self: ZipSource, writer: *std.Io.Writer) !void {
        try self.entry.extractTo(self.reader, writer);
    }
};

fn zip(cd: *std.Io.File.Reader, data: *std.Io.File.Reader, tree: *Tree) !void {
    var iterator = try std.zip.Iterator.init(cd);
    var names: [4096]u8 = undefined;
    while (try iterator.next()) |entry| {
        try cd.seekTo(entry.header_zip_offset);
        const header = try cd.interface.takeStruct(std.zip.CentralDirectoryFileHeader, .little);
        const mode = header.external_file_attributes >> 16;
        const kind = mode & 0o170000;
        if (kind != 0 and kind != 0o100000 and kind != 0o040000) return error.ArchiveLinkRefused;
        if (header.external_file_attributes & 0x400 != 0) return error.ArchiveLinkRefused;
        const name = try entry.getFilename(cd, &names, .{});
        const directory = std.mem.endsWith(u8, name, "/");
        if ((kind == 0o040000 and !directory) or (kind == 0o100000 and directory)) return error.BadArchiveDirectory;
        try tree.accept(.{
            .name = name,
            .size = entry.uncompressed_size,
            .mode = if (mode == 0) 0o644 else mode & 0o777,
            .kind = if (directory) .directory else .file,
        }, ZipSource{ .reader = data, .entry = entry });
    }
}

/// Setup is the only caller. No resolve/build path ever performs HTTP.
pub fn download(gpa: std.mem.Allocator, io: std.Io, artifact: artifacts.Artifact, destination: std.Io.File) !void {
    const Completion = union(enum) { received: anyerror!void, timeout: std.Io.Cancelable!void };
    var results: [2]Completion = undefined;
    var select = std.Io.Select(Completion).init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.received, receive, .{ gpa, io, artifact, destination });
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(180), .awake });
    switch (try select.await()) {
        .received => |result| try result,
        .timeout => return error.ArchiveDownloadTimeout,
    }
}

fn receive(gpa: std.mem.Allocator, io: std.Io, artifact: artifacts.Artifact, destination: std.Io.File) !void {
    const bytes = try gpa.alloc(u8, @intCast(artifact.archive_bytes + 1));
    defer gpa.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    const response = try client.fetch(.{
        .location = .{ .url = artifact.url },
        .response_writer = &writer,
        .redirect_behavior = .unhandled,
    });
    if (response.status != .ok) return error.ArchiveDownloadRefused;
    const content = writer.buffered();
    if (content.len != artifact.archive_bytes) return error.ArchiveSizeMismatch;
    if (!std.mem.eql(u8, &digest.bytes(content), artifact.sha256)) return error.ArchiveHashMismatch;
    try destination.writeStreamingAll(io, content);
    try destination.sync(io);
}
