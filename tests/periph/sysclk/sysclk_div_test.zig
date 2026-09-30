const std = @import("std");
const ra8 = @import("ra8");
const div = ra8.periph.sysclk_div;

test "a divider code is an exponent" {
    try std.testing.expectEqual(@as(?u32, 1), div.ratio(0));
    try std.testing.expectEqual(@as(?u32, 2), div.ratio(1));
    try std.testing.expectEqual(@as(?u32, 4), div.ratio(2));
    try std.testing.expectEqual(@as(?u32, 8), div.ratio(3));
    try std.testing.expectEqual(@as(?u32, 16), div.ratio(4));
    try std.testing.expectEqual(@as(?u32, 32), div.ratio(5));
    try std.testing.expectEqual(@as(?u32, 64), div.ratio(6));
}

test "a code the firmware tree does not define has no ratio" {
    try std.testing.expectEqual(@as(?u32, null), div.ratio(7));
    try std.testing.expectEqual(@as(?u32, null), div.ratio(15));
}

test "the nibble shifts match ra8_sckdivcr_shift_t" {
    try std.testing.expectEqual(@as(u5, 0), div.shift.pckd);
    try std.testing.expectEqual(@as(u5, 4), div.shift.pckc);
    try std.testing.expectEqual(@as(u5, 8), div.shift.pckb);
    try std.testing.expectEqual(@as(u5, 12), div.shift.pcka);
    try std.testing.expectEqual(@as(u5, 16), div.shift.bck);
    try std.testing.expectEqual(@as(u5, 20), div.shift.pcke);
    try std.testing.expectEqual(@as(u5, 24), div.shift.ick);
    try std.testing.expectEqual(@as(u5, 28), div.shift.fck);
}

test "the word the bring-up driver writes decodes to its own dividers" {
    // internal_program_dividers (ra8_cgc.c:527) builds exactly this word:
    // FCLK /8, ICLK /4, PCLKE /4, BCLK /8, PCLKA /8, PCLKB /16, PCLKC /8,
    // PCLKD /4. It is also the value all 26 programming images write.
    const word: u32 = 0x3223_3432;
    try std.testing.expectEqual(@as(?u32, 8), div.ratio(div.codeAt(word, div.shift.fck)));
    try std.testing.expectEqual(@as(?u32, 4), div.ratio(div.codeAt(word, div.shift.ick)));
    try std.testing.expectEqual(@as(?u32, 4), div.ratio(div.codeAt(word, div.shift.pcke)));
    try std.testing.expectEqual(@as(?u32, 8), div.ratio(div.codeAt(word, div.shift.bck)));
    try std.testing.expectEqual(@as(?u32, 8), div.ratio(div.codeAt(word, div.shift.pcka)));
    try std.testing.expectEqual(@as(?u32, 16), div.ratio(div.codeAt(word, div.shift.pckb)));
    try std.testing.expectEqual(@as(?u32, 8), div.ratio(div.codeAt(word, div.shift.pckc)));
    try std.testing.expectEqual(@as(?u32, 4), div.ratio(div.codeAt(word, div.shift.pckd)));
}

test "the second divider word decodes the same way" {
    // internal_program_dividers again: CPUCLK0 /1, CPUCLK1 /4, NPUCLK /1,
    // MRICLK /4.
    const word: u32 = 0x2020;
    try std.testing.expectEqual(@as(?u32, 1), div.ratio(div.codeAt(word, div.shift2.cpuclk0)));
    try std.testing.expectEqual(@as(?u32, 4), div.ratio(div.codeAt(word, div.shift2.cpuclk1)));
    try std.testing.expectEqual(@as(?u32, 1), div.ratio(div.codeAt(word, div.shift2.npuclk)));
    try std.testing.expectEqual(@as(?u32, 4), div.ratio(div.codeAt(word, div.shift2.mriclk)));
}

test "every domain is listed once, in HUM table order" {
    try std.testing.expectEqual(@as(usize, 8), div.domains.len);
    try std.testing.expectEqual(@as(usize, 4), div.domains2.len);
    try std.testing.expectEqualStrings("FCLK", div.domains[0].name);
    try std.testing.expectEqualStrings("PCLKD", div.domains[div.domains.len - 1].name);
    try std.testing.expectEqualStrings("CPUCLK0", div.domains2[0].name);
}
