//! Covers src/chip/core/cpu/text/clrm.zig against the Arm ARM syntax.
const v81m = @import("v81m.zig");

test "CLRM lists the low registers, then LR, then APSR" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xE89F, .hw2 = 0x8003, .text = "clrm {r0, r1, apsr}" },
        .{ .hw1 = 0xE89F, .hw2 = 0x5E00, .text = "clrm {sb, sl, fp, ip, lr}" },
        .{ .hw1 = 0xE89F, .hw2 = 0x8000, .text = "clrm {apsr}" },
        .{ .hw1 = 0xE89F, .hw2 = 0x0010, .text = "clrm {r4}" },
    });
}
