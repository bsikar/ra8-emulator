//! Tests for src/periph/itns.zig.

const std = @import("std");
const ra8 = @import("ra8");
const itns = ra8.periph.nvic.itns;

/// The ITNS words as plain memory.
const Words = struct {
    word: [16]u32 = [_]u32{0} ** 16,

    pub fn readWord(self: *Words, address: u32) !u32 {
        return self.word[(address - itns.base) / 4];
    }
};

test "ITNS spans 0xE000_E380 to 0xE000_E3BC, sixteen words" {
    try std.testing.expectEqual(@as(u32, 0xE000_E380), itns.base);
    try std.testing.expectEqual(itns.base + 4 * 15, itns.last);
}

test "this part's 96 lines reach the first three words" {
    try std.testing.expectEqual(@as(u32, 3), itns.words);
    try std.testing.expectEqual(@as(u32, 0xE000_E388), itns.wordFor(95));
}

test "every line targets Secure out of reset" {
    var words = Words{};
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 0));
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 95));
}

test "a set bit sends only its own line to Non-secure" {
    var words = Words{};
    words.word[1] = itns.bitFor(37);
    try std.testing.expectEqual(itns.Target.non_secure, try itns.target(&words, 37));
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 36));
    try std.testing.expectEqual(itns.Target.secure, try itns.target(&words, 5));
}

test "an exception number maps through the first external line" {
    var words = Words{};
    words.word[0] = itns.bitFor(0);
    try std.testing.expectEqual(itns.Target.non_secure, try itns.targetOf(&words, 16));
    try std.testing.expectError(itns.Error.NotAnIrq, itns.targetOf(&words, 15));
}

test "a line past this part's lines is refused" {
    var words = Words{};
    try std.testing.expectError(itns.Error.NotAnIrq, itns.target(&words, 96));
}
