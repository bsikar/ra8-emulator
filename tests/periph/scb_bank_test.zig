//! Tests for src/periph/scb_bank.zig.

const std = @import("std");
const ra8 = @import("ra8");
const bank = ra8.periph.scb_bank;
const alias = ra8.periph.scs_alias;

fn word(address: u32, secure: bool) u32 {
    const target = alias.route(address, secure).register;
    return bank.backing(target).word;
}

test "the table matches the D1.2 attribute lines" {
    try std.testing.expectEqual(bank.Banking.banked, bank.banking(0xE000_ED08).?); // VTOR
    try std.testing.expectEqual(bank.Banking.banked, bank.banking(0xE000_ED88).?); // CPACR
    try std.testing.expectEqual(bank.Banking.bit_by_bit, bank.banking(0xE000_ED0C).?); // AIRCR
    try std.testing.expectEqual(bank.Banking.bit_by_bit, bank.banking(0xE000_ED28).?); // CFSR
    try std.testing.expectEqual(bank.Banking.not_banked, bank.banking(0xE000_ED2C).?); // HFSR
    try std.testing.expectEqual(bank.Banking.not_banked, bank.banking(0xE000_ED00).?); // CPUID
}

test "addresses the table has not read up on are null" {
    try std.testing.expect(bank.banking(0xE000_ED3C) == null);
    try std.testing.expect(bank.banking(0xE000_ED90) == null);
    try std.testing.expect(bank.banking(0xE000_E100) == null);
}

test "VTOR: Secure and Non-secure copies live apart" {
    try std.testing.expectEqual(@as(u32, 0xE000_ED08), word(0xE000_ED08, true));
    try std.testing.expectEqual(@as(u32, 0xE002_ED08), word(0xE000_ED08, false));
}

test "Secure code on VTOR_NS and Non-secure code on VTOR share one word" {
    try std.testing.expectEqual(word(0xE000_ED08, false), word(0xE002_ED08, true));
    try std.testing.expectEqual(ra8.core.memmap.scb.vtor_ns, word(0xE002_ED08, true));
}

test "an unbanked register has one home from every view" {
    try std.testing.expectEqual(@as(u32, 0xE000_ED2C), word(0xE000_ED2C, true));
    try std.testing.expectEqual(@as(u32, 0xE000_ED2C), word(0xE000_ED2C, false));
    try std.testing.expectEqual(@as(u32, 0xE000_ED2C), word(0xE002_ED2C, true));
}

test "a bit-by-bit register is handed back, not placed" {
    const target = alias.route(0xE000_ED24, false).register;
    const answer = bank.backing(target);
    try std.testing.expectEqual(@as(u32, 0xE000_ED24), answer.bit_by_bit.address);
    try std.testing.expectEqual(alias.View.non_secure, answer.bit_by_bit.view);
}
