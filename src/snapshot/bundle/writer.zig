//! Streaming tar envelope. The caller freezes inputs and publishes only after finish succeeds.
const std = @import("std");

const file = @import("../file.zig");
const manifest = @import("manifest.zig");
const names = @import("names.zig");

pub const Source = struct {
    reader: *std.Io.Reader,
    size: u64,
};

pub const Recording = struct {
    root: Source,
    branches: Source,
};

pub const Space = enum { log, objects };

pub const Writer = struct {
    tar: std.tar.Writer,
    state: enum { snapshot_only, recording, failed, finished },
    last_path: [128]u8 = undefined,
    last_len: usize = 0,
    has_log: bool = false,

    /// Readers need at least 12 bytes of buffer for snapshot header validation.
    /// Inputs remain caller-owned; this does not flush or close the destination.
    pub fn init(
        output: *std.Io.Writer,
        metadata: manifest.Metadata,
        snapshot: Source,
        recording: ?Recording,
    ) !Writer {
        var buffer: [8192]u8 = undefined;
        const json = try manifest.encode(&buffer, metadata, recording != null);
        try sizeCheck(snapshot.size);
        if (recording) |history| {
            try sizeCheck(history.root.size);
            try sizeCheck(history.branches.size);
        }
        try snapshotCheck(snapshot);

        var self: Writer = .{
            .tar = .{ .underlying_writer = output },
            .state = if (recording != null) .recording else .snapshot_only,
        };
        try self.tar.writeFileBytes("manifest.json", json, .{ .mode = 0o600 });
        try self.write("state.ra8snap", snapshot);
        if (recording) |history| {
            try self.write("recording/root.bin", history.root);
            try self.write("recording/branches.bin", history.branches);
        }
        return self;
    }

    /// Supply all committed log segments and object/pack files, sorted by archive path.
    /// One file can be opened, streamed, and closed before opening the next.
    pub fn add(self: *Writer, space: Space, leaf: []const u8, source: Source) !void {
        if (self.state != .recording) return error.InvalidState;
        errdefer self.state = .failed;
        try names.check(leaf);
        try sizeCheck(source.size);

        var buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&buffer, "recording/{s}/{s}", .{ @tagName(space), leaf });
        if (std.mem.order(u8, self.last_path[0..self.last_len], path) != .lt) {
            return error.UnorderedEntry;
        }
        try self.write(path, source);
        @memcpy(self.last_path[0..path.len], path);
        self.last_len = path.len;
        self.has_log = self.has_log or space == .log;
    }

    pub fn finish(self: *Writer) !void {
        if (self.state != .snapshot_only and self.state != .recording) return error.InvalidState;
        errdefer self.state = .failed;
        if (self.state == .recording and !self.has_log) return error.MissingLog;
        // Two zero blocks make a standalone tar, rather than an unterminated stream.
        try self.tar.finishPedantically();
        self.state = .finished;
    }

    fn write(self: *Writer, path: []const u8, source: Source) !void {
        try self.tar.writeFileStream(path, source.size, source.reader, .{ .mode = 0o600 });
    }
};

fn sizeCheck(size: u64) !void {
    // USTAR's size field holds eleven octal digits; never wrap a large recording file.
    if (size > std.math.maxInt(u33)) return error.FileTooLarge;
}

fn snapshotCheck(source: Source) !void {
    if (source.size < 12) return error.Truncated;
    if (source.reader.buffer.len < 12) return error.ReaderBufferTooSmall;
    const header = try source.reader.peek(12);
    if (!std.mem.eql(u8, header[0..8], &file.magic)) return error.BadMagic;
    if (std.mem.readInt(u32, header[8..12], .little) != file.version) return error.BadVersion;
}
