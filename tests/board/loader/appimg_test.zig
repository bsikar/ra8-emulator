//! The `.ra8app` reader admits what ra8-firmware's loader admits.
const std = @import("std");
const ra8 = @import("ra8");
const appimg = ra8.board.appimg;

const code_len = 16;
const data_len = 8;
const image_len = appimg.header_len + code_len + data_len;

fn put(bytes: []u8, index: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[index * 4 ..][0..4], value, .little);
}

/// A valid hello-world container: 16 bytes of code, 8 of data.
fn sample() [image_len]u8 {
    var bytes = @as([image_len]u8, @splat(0));
    const words = [_]u32{ appimg.magic, appimg.version, 4, code_len, data_len, 0x800, 1, appimg.Capability.display };
    for (words, 0..) |value, index| put(&bytes, index, value);
    @memcpy(bytes[32..][0..9], "com.hello");
    @memcpy(bytes[64..][0..5], "Hello");
    for (bytes[appimg.header_len..], 0..) |*byte, index| byte.* = @intCast(index + 1);
    return bytes;
}

test "the header is 160 bytes with the signature last" {
    try std.testing.expectEqual(@as(usize, 160), appimg.header_len);
    try std.testing.expectEqual(@as(usize, 96), appimg.signature_offset);
}

test "a valid container parses and its fields are read" {
    const bytes = sample();
    const header = try appimg.parse(&bytes);
    try std.testing.expectEqualStrings("com.hello", header.id());
    try std.testing.expectEqualStrings("Hello", header.name());
    try std.testing.expectEqual(@as(u32, 4), header.entry_offset);
    try std.testing.expectEqual(@as(usize, image_len), header.imageLen());
    try std.testing.expectEqual(@as(u8, 1), appimg.code(header, &bytes)[0]);
    try std.testing.expectEqual(@as(usize, data_len), appimg.data(header, &bytes).len);
    try std.testing.expectEqual(@as(u8, code_len + 1), appimg.data(header, &bytes)[0]);
}

test "wrong magic, revision, capability or text is a validation refusal" {
    var bytes = sample();
    put(&bytes, 0, 0x41385241);
    try std.testing.expectError(error.Validation, appimg.parse(&bytes));
    bytes = sample();
    put(&bytes, 1, 2);
    try std.testing.expectError(error.Validation, appimg.parse(&bytes));
    bytes = sample();
    put(&bytes, 7, 0x8);
    try std.testing.expectError(error.Validation, appimg.parse(&bytes));
    bytes = sample();
    @memset(bytes[32..64], 'x');
    try std.testing.expectError(error.Validation, appimg.parse(&bytes));
    bytes = sample();
    @memset(bytes[32..64], 0);
    try std.testing.expectError(error.Validation, appimg.parse(&bytes));
}

test "an app asking for a newer API is unsupported" {
    var bytes = sample();
    put(&bytes, 6, appimg.api_version_current + 1);
    try std.testing.expectError(error.Unsupported, appimg.parse(&bytes));
}

test "sizes and the entry are held to their ranges" {
    const cases = [_]struct { index: usize, value: u32 }{
        .{ .index = 3, .value = 0 },
        .{ .index = 3, .value = appimg.segment_max + 1 },
        .{ .index = 4, .value = appimg.segment_max + 1 },
        .{ .index = 5, .value = appimg.stack_min - 1 },
        .{ .index = 5, .value = appimg.segment_max + 1 },
        .{ .index = 2, .value = code_len },
    };
    for (cases) |case| {
        var bytes = sample();
        put(&bytes, case.index, case.value);
        try std.testing.expectError(error.OutOfRange, appimg.parse(&bytes));
    }
}

test "a file shorter than its header or its payload is short" {
    const bytes = sample();
    try std.testing.expectError(error.ShortImage, appimg.parse(bytes[0 .. appimg.header_len - 1]));
    try std.testing.expectError(error.ShortImage, appimg.parse(bytes[0 .. image_len - 1]));
}
