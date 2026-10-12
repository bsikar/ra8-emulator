//! The chunked load protocol (RA8EMU-1174): the client helper picks the
//! single Load wire format for small images and streams ordered,
//! checksummed chunks for large ones, and the Assembler assembles exactly
//! what was streamed.

const std = @import("std");
const ra8 = @import("ra8");

const proto = ra8.rpc.session.rpc;
const chunk_load = ra8.rpc.session.load_chunks;

/// Records the calls loadImageCall makes, whatever their argument shape.
const CallMock = struct {
    seen: [64]proto.Method = undefined,
    n: usize = 0,
    total: u64 = 0,
    checksum: u32 = 0,
    offsets: [256]u64 = undefined,
    on: usize = 0,
    bytes_total: usize = 0,
    image_len: usize = 0,

    pub fn call(self: *CallMock, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
        self.seen[self.n] = method;
        self.n += 1;
        if (comptime @hasField(Args, "total_len")) {
            self.total = args.total_len;
            self.checksum = args.checksum;
        }
        if (comptime @hasField(Args, "offset")) {
            self.offsets[self.on] = args.offset;
            self.on += 1;
        }
        if (comptime @hasField(Args, "bytes")) self.bytes_total += args.bytes.len;
        if (comptime @hasField(Args, "image")) self.image_len = args.image.len;
        return if (Reply == proto.Ack) .{ .accepted = 1 } else undefined;
    }
};

/// Records the sends loadImageSend makes, matching the gui link's shape.
const SendMock = struct {
    seen: [64]proto.Method = undefined,
    n: usize = 0,
    total: u64 = 0,
    checksum: u32 = 0,
    offsets: [256]u64 = undefined,
    on: usize = 0,
    bytes_total: usize = 0,
    image_len: usize = 0,
    next_id: u32 = 100,

    pub fn send(self: *SendMock, comptime Args: type, comptime method: proto.Method, args: Args) !u32 {
        self.seen[self.n] = method;
        self.n += 1;
        if (comptime @hasField(Args, "total_len")) {
            self.total = args.total_len;
            self.checksum = args.checksum;
        }
        if (comptime @hasField(Args, "offset")) {
            self.offsets[self.on] = args.offset;
            self.on += 1;
        }
        if (comptime @hasField(Args, "bytes")) self.bytes_total += args.bytes.len;
        if (comptime @hasField(Args, "image")) self.image_len = args.image.len;
        self.next_id += 1;
        return self.next_id;
    }
};

test "a small image keeps the single Load wire format" {
    var mock = CallMock{};
    const ack = try chunk_load.loadImageCall(&mock, .cpu0, "hello");
    try std.testing.expectEqual(@as(u8, 1), ack.accepted);
    try std.testing.expectEqual(@as(usize, 1), mock.n);
    try std.testing.expectEqual(proto.Method.load, mock.seen[0]);
    try std.testing.expectEqual(@as(usize, 5), mock.image_len);
}

test "a small image over the gui link keeps the single Load wire format" {
    var mock = SendMock{};
    const id = try chunk_load.loadImageSend(&mock, .cpu1, "hello");
    try std.testing.expectEqual(@as(u32, 101), id);
    try std.testing.expectEqual(@as(usize, 1), mock.n);
    try std.testing.expectEqual(proto.Method.load, mock.seen[0]);
}

test "a large image streams ordered checksummed chunks and commits with load_end" {
    const image = try std.testing.allocator.alloc(u8, proto.max_payload + 1000);
    defer std.testing.allocator.free(image);
    for (image, 0..) |*byte, i| byte.* = @intCast(i % 251);
    var mock = CallMock{};
    const ack = try chunk_load.loadImageCall(&mock, .cpu0, image);
    try std.testing.expectEqual(@as(u8, 1), ack.accepted);
    try std.testing.expectEqual(@as(usize, 4), mock.n);
    try std.testing.expectEqual(proto.Method.load_begin, mock.seen[0]);
    try std.testing.expectEqual(proto.Method.load_chunk, mock.seen[1]);
    try std.testing.expectEqual(proto.Method.load_chunk, mock.seen[2]);
    try std.testing.expectEqual(proto.Method.load_end, mock.seen[3]);
    try std.testing.expectEqual(image.len, mock.total);
    try std.testing.expectEqual(std.hash.Crc32.hash(image), mock.checksum);
    try std.testing.expectEqual(@as(u64, 0), mock.offsets[0]);
    try std.testing.expectEqual(@as(u64, proto.max_payload), mock.offsets[1]);
    try std.testing.expectEqual(image.len, mock.bytes_total);
}

test "a large image over the gui link streams the same chunks" {
    const image = try std.testing.allocator.alloc(u8, proto.max_payload + 1);
    defer std.testing.allocator.free(image);
    @memset(image, 7);
    var mock = SendMock{};
    const id = try chunk_load.loadImageSend(&mock, .cpu0, image);
    try std.testing.expectEqual(@as(u32, 104), id);
    try std.testing.expectEqual(@as(usize, 4), mock.n);
    try std.testing.expectEqual(proto.Method.load_begin, mock.seen[0]);
    try std.testing.expectEqual(proto.Method.load_end, mock.seen[3]);
    try std.testing.expectEqual(image.len, mock.bytes_total);
}

test "an image beyond the plug cap is refused before anything is sent" {
    const image = try std.testing.allocator.alloc(u8, chunk_load.max_image + 1);
    defer std.testing.allocator.free(image);
    var mock = CallMock{};
    try std.testing.expectError(error.Oversize, chunk_load.loadImageCall(&mock, .cpu0, image));
    try std.testing.expectEqual(@as(usize, 0), mock.n);
}

test "the assembler puts the streamed chunks back together" {
    const bytes = "an image in pieces";
    var asm2 = chunk_load.Assembler{};
    try asm2.begin(std.testing.allocator, bytes.len, std.hash.Crc32.hash(bytes));
    try asm2.chunk(0, bytes[0..6]);
    try asm2.chunk(6, bytes[6..]);
    const image = try asm2.end();
    defer std.testing.allocator.free(image);
    try std.testing.expectEqualStrings(bytes, image);
    asm2.drop();
}

test "the assembler refuses a wrong checksum, out-of-order or short stream" {
    const bytes = "checksum me";
    var asm2 = chunk_load.Assembler{};
    try asm2.begin(std.testing.allocator, bytes.len, std.hash.Crc32.hash(bytes) ^ 1);
    try asm2.chunk(0, bytes);
    try std.testing.expectError(error.BadChecksum, asm2.end());
    asm2.drop();

    try asm2.begin(std.testing.allocator, bytes.len, std.hash.Crc32.hash(bytes));
    try std.testing.expectError(error.BadArgs, asm2.chunk(4, bytes[0..]));
    try std.testing.expectError(error.BadArgs, asm2.end());
    asm2.drop();

    try std.testing.expectError(error.BadArgs, asm2.begin(std.testing.allocator, 0, 0));
    try std.testing.expectError(error.BadArgs, asm2.begin(std.testing.allocator, chunk_load.max_image + 1, 0));
}
