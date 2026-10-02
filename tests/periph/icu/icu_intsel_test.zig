//! Covers src/periph/icu/icu_intsel.zig: the INTSELR bank's addresses, its
//! fixed-zero bits, narrow stores, and the per-event core answer.
const std = @import("std");
const ra8 = @import("ra8");

const intsel = ra8.periph.icu.intsel;

test "the bank sits where the COMMON_ICU map puts it" {
    try std.testing.expectEqual(@as(u32, 0x4000_6040), intsel.wordAddress(0));
    try std.testing.expectEqual(@as(u32, 0x4000_60BC), intsel.wordAddress(31));
    try std.testing.expectEqual(@as(usize, 1024), intsel.events);
}

test "every event is a CPU0 factor out of reset" {
    const bank = intsel.Intsel{};
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(1));
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(1023));
}

test "a set IS bit hands that event to CPU1 and no other" {
    var bank = intsel.Intsel{};
    bank.write(intsel.wordAddress(0), 4, 1 << 2);
    try std.testing.expectEqual(intsel.Core.cpu1, bank.coreFor(2));
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(1));
    try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(3));
}

test "event zero and the per-core events ignore a store" {
    var bank = intsel.Intsel{};
    for (0..intsel.words) |index| bank.write(intsel.wordAddress(index), 4, 0xFFFF_FFFF);
    for (intsel.fixed) |event| {
        try std.testing.expectEqual(intsel.Core.cpu0, bank.coreFor(event));
    }
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFE), bank.read(intsel.wordAddress(0), 4));
    try std.testing.expectEqual(@as(u32, 0xE4FF_FFFF), bank.read(intsel.wordAddress(2), 4));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFDF), bank.read(intsel.wordAddress(3), 4));
    try std.testing.expectEqual(intsel.Core.cpu1, bank.coreFor(90));
}

test "a byte store keeps the lanes it does not name" {
    var bank = intsel.Intsel{};
    bank.write(intsel.wordAddress(1), 4, 0x0000_00FF);
    bank.write(intsel.wordAddress(1) + 2, 1, 0x80);
    try std.testing.expectEqual(@as(u32, 0x0080_00FF), bank.read(intsel.wordAddress(1), 4));
    try std.testing.expectEqual(@as(u32, 0x80), bank.read(intsel.wordAddress(1) + 2, 1));
    try std.testing.expectEqual(intsel.Core.cpu1, bank.coreFor(32 + 23));
}

test "an address outside the bank reads zero and keeps nothing" {
    var bank = intsel.Intsel{};
    bank.write(intsel.base + intsel.win_span, 4, 0xFFFF_FFFF);
    try std.testing.expectEqual(@as(u32, 0), bank.read(intsel.base + intsel.win_span, 4));
    try std.testing.expectEqual(@as(u32, 0), bank.read(intsel.base - 4, 4));
}

test "the block names the bank's window" {
    var bank = intsel.Intsel{};
    const window = bank.block();
    try std.testing.expectEqual(intsel.base, window.base);
    try std.testing.expectEqual(intsel.win_span, window.size);
}
