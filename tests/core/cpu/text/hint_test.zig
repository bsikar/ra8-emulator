//! Covers src/core/cpu/text/hint.zig against Capstone.
const capstone = @import("capstone.zig");
const v81m = @import("v81m.zig");

test "every 16-bit hint encoding prints the way Capstone does" {
    try capstone.expectGroupMatches("hint");
}

test "BTI T1 uses its Armv8.1-M alias" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF3AF, .hw2 = 0x800F, .text = "bti" },
    });
}

/// Every 32-bit hint number except BTI (covered against the Arm ARM in
/// pac_test.zig), plus a nonzero hw2[10:8] (not a hint).
const wide = blk: {
    var out: [257]u16 = undefined;
    for (0..256) |n| out[n] = 0x8000 | @as(u16, n);
    out[0x0F] = 0x8100;
    out[256] = 0x8100;
    break :blk out;
};

test "every other 32-bit hint encoding prints the way Capstone does" {
    try capstone.expectWideGroupMatches("hint", 0xFFFF, 0xF3AF, &wide);
}
