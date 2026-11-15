//! Anonymous transfer files live under one private history lease, removed on close/crash.
const std = @import("std");

const wire = @import("wire.zig");

const history = @import("ra8_host").history;

pub const Write = *const fn (*anyopaque, *std.Io.Writer) anyerror!void;

pub const Spool = struct {
    gpa: std.mem.Allocator,
    base: history.base.Base,
    session: history.session.Session,
    next: u64 = 1,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !*Spool {
        const self = try gpa.create(Spool);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .base = undefined, .session = undefined };
        self.base = try history.base.Base.openConfigured(gpa, io, path, .cache, .{ .recover = false });
        errdefer self.base.close();
        self.session = try history.session.Session.create(&self.base, .{});
        return self;
    }

    pub fn close(self: *Spool) !void {
        const gpa = self.gpa;
        defer gpa.destroy(self);
        defer self.base.close();
        _ = try self.session.close(null, .move);
    }

    pub fn file(self: *Spool) !std.Io.File {
        if (self.next == std.math.maxInt(u64)) return error.IdExhausted;
        var buffer: [64]u8 = undefined;
        const leaf = try std.fmt.bufPrint(&buffer, "artifact-{d}", .{self.next});
        self.next += 1;
        return history.scratch.open(&self.session, .scratch, leaf);
    }

    pub fn save(self: *Spool, context: *anyopaque, write: Write, max: u64) !std.Io.File {
        var count = std.Io.Writer.Discarding.init(&.{});
        try write(context, &count.writer);
        const size = count.fullCount();
        if (size > max) return error.TooLarge;
        const result = try self.file();
        errdefer result.close(self.base.io);
        var buffer: [65536]u8 = undefined;
        var output = result.writer(self.base.io, &buffer);
        try write(context, &output.interface);
        try output.interface.flush();
        if ((try result.stat(self.base.io)).size != size) return error.SourceChanged;
        return result;
    }
};

pub fn checksum(file: std.Io.File, io: std.Io) ![32]u8 {
    var state = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [65536]u8 = undefined;
    var offset: u64 = 0;
    const size = (try file.stat(io)).size;
    if (size > wire.max_bundle) return error.TooLarge;
    while (offset < size) {
        const bytes = buffer[0..@intCast(@min(buffer.len, size - offset))];
        const got = try file.readPositionalAll(io, bytes, offset);
        if (got != bytes.len) return error.SourceChanged;
        state.update(buffer[0..got]);
        offset += got;
    }
    if ((try file.stat(io)).size != size) return error.SourceChanged;
    var digest: [32]u8 = undefined;
    state.final(&digest);
    return digest;
}
