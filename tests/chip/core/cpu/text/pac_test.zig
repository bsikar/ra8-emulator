//! Covers src/chip/core/cpu/text/pac.zig against the Arm ARM syntax.
const v81m = @import("v81m.zig");

test "PAC, PACBTI and AUT name R12, LR and SP" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xF3AF, .hw2 = 0x800D, .text = "pacbti ip, lr, sp" },
        .{ .hw1 = 0xF3AF, .hw2 = 0x801D, .text = "pac ip, lr, sp" },
        .{ .hw1 = 0xF3AF, .hw2 = 0x802D, .text = "aut ip, lr, sp" },
    });
}

test "PACG, AUTG and BXAUT print their three registers" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xFB61, .hw2 = 0xF002, .text = "pacg r0, r1, r2" },
        .{ .hw1 = 0xFB6C, .hw2 = 0xFB0E, .text = "pacg fp, ip, lr" },
        .{ .hw1 = 0xFB54, .hw2 = 0x3F05, .text = "autg r3, r4, r5" },
        .{ .hw1 = 0xFB5E, .hw2 = 0xCF1D, .text = "bxaut ip, lr, sp" },
    });
}
