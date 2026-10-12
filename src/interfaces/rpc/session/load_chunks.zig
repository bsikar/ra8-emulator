//! The chunked load protocol (RA8EMU-1174): an image larger than one
//! payload streams in ordered, checksummed chunks and commits through the
//! same session load call a single Load takes, so the loaded semantics
//! (the loaded event, paused at reset) do not change. Images within one
//! payload keep the single Load wire format.

const std = @import("std");
const proto = @import("rpc.zig");
const handlers = @import("handlers.zig");

const Ack = handlers.Ack;
const Context = handlers.Context;

/// The largest image one chunked load carries. The board's own plug cap,
/// for the same reason.
pub const max_image: u64 = 64 * 1024 * 1024;

/// Assembles a chunked load between load_begin and load_end (RA8EMU-1174).
pub const Assembler = struct {
    gpa: std.mem.Allocator = undefined,
    buffer: []u8 = &.{},
    got: usize = 0,
    checksum: u32 = 0,

    /// Starts a fresh assembly, dropping any in-flight one.
    pub fn begin(self: *Assembler, gpa: std.mem.Allocator, total_len: u64, checksum: u32) !void {
        self.drop();
        if (total_len == 0 or total_len > max_image) return error.BadArgs;
        self.gpa = gpa;
        self.buffer = try gpa.alloc(u8, @intCast(total_len));
        self.got = 0;
        self.checksum = checksum;
    }

    /// Copies the next chunk. Chunks arrive in order, with no gaps.
    pub fn chunk(self: *Assembler, offset: u64, bytes: []const u8) !void {
        if (self.buffer.len == 0 or offset != self.got or bytes.len == 0) return error.BadArgs;
        if (bytes.len > self.buffer.len - self.got) return error.BadArgs;
        @memcpy(self.buffer[self.got..][0..bytes.len], bytes);
        self.got += bytes.len;
    }

    /// Verifies and hands the assembled image over. The caller frees it
    /// with the allocator the server was opened with.
    pub fn end(self: *Assembler) ![]u8 {
        if (self.buffer.len == 0 or self.got != self.buffer.len) return error.BadArgs;
        if (std.hash.Crc32.hash(self.buffer) != self.checksum) return error.BadChecksum;
        const image = self.buffer;
        self.buffer = &.{};
        self.got = 0;
        self.checksum = 0;
        return image;
    }

    /// Frees any in-flight assembly; safe when nothing is in flight.
    pub fn drop(self: *Assembler) void {
        if (self.buffer.len != 0) self.gpa.free(self.buffer);
        self.buffer = &.{};
        self.got = 0;
        self.checksum = 0;
    }
};

pub fn loadBegin(context: *Context, args: proto.LoadBegin) Ack {
    const gpa = context.gpa orelse return .{ .err = .bad_args };
    context.chunks.begin(gpa, args.total_len, args.checksum) catch return .{ .err = .bad_args };
    return .{ .ok = .{ .accepted = 1 } };
}

pub fn loadChunk(context: *Context, args: proto.LoadChunk) Ack {
    context.chunks.chunk(args.offset, args.bytes) catch return .{ .err = .bad_args };
    return .{ .ok = .{ .accepted = 1 } };
}

/// Commits the assembly through the same call one Load takes, so the
/// semantics are identical by construction (RA8EMU-1174).
pub fn loadEnd(context: *Context, args: proto.CoreOnly) Ack {
    const image = context.chunks.end() catch return .{ .err = .bad_args };
    defer if (context.gpa) |gpa| gpa.free(image);
    return handlers.load(context, .{ .core = args.core, .image = image });
}

/// Sends one image over `client.call(Reply, Args, method, args)` (the ctl
/// client): images within one payload keep the single Load wire format;
/// larger ones stream ordered, checksummed chunks (RA8EMU-1174).
pub fn loadImageCall(client: anytype, core: proto.Core, image: []const u8) !proto.Ack {
    if (image.len <= proto.max_payload)
        return client.call(proto.Ack, proto.Load, .load, .{ .core = core, .image = image });
    if (image.len > max_image) return error.Oversize;
    _ = try client.call(proto.Ack, proto.LoadBegin, .load_begin, .{
        .core = core,
        .total_len = image.len,
        .checksum = std.hash.Crc32.hash(image),
    });
    var offset: usize = 0;
    while (offset < image.len) : (offset += proto.max_payload) {
        const stop = @min(offset + proto.max_payload, image.len);
        _ = try client.call(proto.Ack, proto.LoadChunk, .load_chunk, .{
            .core = core,
            .offset = offset,
            .bytes = image[offset..stop],
        });
    }
    return client.call(proto.Ack, proto.CoreOnly, .load_end, .{ .core = core });
}

/// Sends one image over `send(Args, method, args)` (the gui link), whose
/// response comes back by pump: same formats as loadImageCall.
pub fn loadImageSend(link: anytype, core: proto.Core, image: []const u8) !u32 {
    if (image.len <= proto.max_payload)
        return link.send(proto.Load, .load, .{ .core = core, .image = image });
    if (image.len > max_image) return error.Oversize;
    _ = try link.send(proto.LoadBegin, .load_begin, .{
        .core = core,
        .total_len = image.len,
        .checksum = std.hash.Crc32.hash(image),
    });
    var offset: usize = 0;
    while (offset < image.len) : (offset += proto.max_payload) {
        const stop = @min(offset + proto.max_payload, image.len);
        _ = try link.send(proto.LoadChunk, .load_chunk, .{
            .core = core,
            .offset = offset,
            .bytes = image[offset..stop],
        });
    }
    return link.send(proto.CoreOnly, .load_end, .{ .core = core });
}
