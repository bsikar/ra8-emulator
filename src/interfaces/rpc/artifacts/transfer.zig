//! One connection owns at most one anonymous upload or download.
const std = @import("std");

const wire = @import("wire.zig");

pub const Transfer = struct {
    io: std.Io = undefined,
    file: ?std.Io.File = null,
    kind: enum { none, upload, download } = .none,
    id: u64 = 0,
    total: u64 = 0,
    offset: u64 = 0,
    expected: [32]u8 = @splat(0),
    hash: std.crypto.hash.sha2.Sha256 = undefined,

    pub fn drop(self: *Transfer) void {
        if (self.file) |file| file.close(self.io);
        self.* = .{};
    }

    /// Takes ownership of file only on success.
    pub fn begin(
        self: *Transfer,
        io: std.Io,
        file: std.Io.File,
        id: u64,
        total: u64,
        digest: [32]u8,
        upload: bool,
    ) !void {
        if (self.file != null) return error.TransferBusy;
        if (id == 0 or total == 0 or total > wire.max_bundle) return error.TooLarge;
        self.* = .{
            .io = io,
            .file = file,
            .id = id,
            .total = total,
            .expected = digest,
            .kind = if (upload) .upload else .download,
            .hash = .init(.{}),
        };
    }

    pub fn append(self: *Transfer, args: wire.Chunk) !void {
        errdefer self.drop();
        if (self.kind != .upload or args.id != self.id or args.offset != self.offset) return error.TransferState;
        if (args.bytes.len == 0 or args.bytes.len > wire.max_chunk or
            args.bytes.len > self.total - self.offset) return error.TransferState;
        try self.file.?.writePositionalAll(self.io, args.bytes, self.offset);
        self.hash.update(args.bytes);
        self.offset += args.bytes.len;
    }

    pub fn read(self: *Transfer, args: wire.Read, buffer: []u8) !wire.Chunk {
        errdefer self.drop();
        if (self.kind != .download or args.id != self.id or args.offset != self.offset) return error.TransferState;
        if (args.length == 0 or args.length > wire.max_chunk or self.offset == self.total) return error.TransferState;
        const size = @min(@as(u64, args.length), self.total - self.offset);
        if (size > buffer.len) return error.TooLarge;
        const bytes = buffer[0..@intCast(size)];
        if (try self.file.?.readPositionalAll(self.io, bytes, self.offset) != bytes.len) return error.Truncated;
        const at = self.offset;
        self.offset += size;
        return .{ .id = self.id, .offset = at, .bytes = bytes };
    }

    pub fn complete(self: *Transfer, id: u64) !std.Io.File {
        errdefer self.drop();
        if (self.kind != .upload or id != self.id or self.offset != self.total) return error.TransferState;
        var digest: [32]u8 = undefined;
        self.hash.final(&digest);
        if (!std.mem.eql(u8, &digest, &self.expected)) return error.BadChecksum;
        return self.file.?;
    }
};
