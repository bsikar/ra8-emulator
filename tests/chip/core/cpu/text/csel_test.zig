//! Covers src/chip/core/cpu/text/csel.zig against the Arm ARM syntax.
const v81m = @import("v81m.zig");

test "CSEL, CSINC, CSINV and CSNEG print in full when no alias applies" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEA51, .hw2 = 0x8023, .text = "csel r0, r1, r3, hs" },
        .{ .hw1 = 0xEA5F, .hw2 = 0x8013, .text = "csel r0, zr, r3, ne" },
        .{ .hw1 = 0xEA51, .hw2 = 0x9032, .text = "csinc r0, r1, r2, lo" },
        .{ .hw1 = 0xEA5C, .hw2 = 0xAB83, .text = "csinv fp, ip, r3, hi" },
        .{ .hw1 = 0xEA5F, .hw2 = 0xB01F, .text = "csneg r0, zr, zr, ne" },
    });
}

test "Rn == Rm prints as CINC, CINV or CNEG on the inverted condition" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEA54, .hw2 = 0x9C04, .text = "cinc ip, r4, ne" },
        .{ .hw1 = 0xEA54, .hw2 = 0xA5B4, .text = "cinv r5, r4, ge" },
        .{ .hw1 = 0xEA54, .hw2 = 0xB5D4, .text = "cneg r5, r4, gt" },
        .{ .hw1 = 0xEA5C, .hw2 = 0xAB8C, .text = "cinv fp, ip, ls" },
    });
}

test "both sources the zero register print as CSET and CSETM" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEA5F, .hw2 = 0x901F, .text = "cset r0, eq" },
        .{ .hw1 = 0xEA5F, .hw2 = 0xA2CF, .text = "csetm r2, le" },
    });
}
