//! Tests for src/core/systick_bank.zig: the Secure and Non-secure SysTick of
//! one core.
const std = @import("std");
const ra8 = @import("ra8");
const bank = ra8.core.systick_bank;
const clocks = ra8.periph.clocks;

const run = clocks.csr_enable | clocks.csr_tickint;

test "the two timers of a bank count at their own reloads" {
    var b = bank.Bank{};
    b.secure = .{ .csr = run, .rvr = 9, .cvr = 9 };
    b.non_secure = .{ .csr = run, .rvr = 99, .cvr = 99 };
    b.advance(25);
    try std.testing.expectEqual(@as(u32, 4), b.secure.cvr);
    try std.testing.expectEqual(@as(u32, 74), b.non_secure.cvr);
    try std.testing.expect(b.secure.pending);
    try std.testing.expect(!b.non_secure.pending);
}

test "only the timer that wrapped pends and sets COUNTFLAG" {
    var b = bank.Bank{};
    b.secure = .{ .csr = clocks.csr_enable, .rvr = 3, .cvr = 3 };
    b.non_secure = .{ .csr = run, .rvr = 3, .cvr = 3 };
    b.advance(4);
    try std.testing.expect(!b.secure.pending);
    try std.testing.expect(b.non_secure.pending);
    try std.testing.expect(b.secure.readCsr() & clocks.csr_countflag != 0);
    try std.testing.expect(b.secure.readCsr() & clocks.csr_countflag == 0);
}

test "a disabled timer does not move while its pair runs" {
    var b = bank.Bank{};
    b.secure = .{ .rvr = 9, .cvr = 9 };
    b.non_secure = .{ .csr = run, .rvr = 9, .cvr = 9 };
    b.advance(5);
    try std.testing.expectEqual(@as(u32, 9), b.secure.cvr);
    try std.testing.expectEqual(@as(u32, 4), b.non_secure.cvr);
    try std.testing.expectEqual(@as(u64, 0), b.secure.advance(100));
}

test "the normal window answers in the requester's own state" {
    try std.testing.expectEqual(bank.Route{ .view = .secure, .register = .csr }, bank.route(0xE000_E010, .secure).?);
    try std.testing.expectEqual(bank.Route{ .view = .non_secure, .register = .cvr }, bank.route(0xE000_E018, .non_secure).?);
    try std.testing.expectEqual(bank.Route{ .view = .secure, .register = .calib }, bank.route(0xE000_E01C, .secure).?);
}

test "the alias is Secure code's view of the Non-secure timer" {
    try std.testing.expectEqual(bank.Route{ .view = .non_secure, .register = .rvr }, bank.route(0xE002_E014, .secure).?);
    try std.testing.expectEqual(@as(?bank.Route, null), bank.route(0xE002_E014, .non_secure));
}

test "addresses outside both windows reach no timer" {
    try std.testing.expectEqual(@as(?bank.Route, null), bank.route(0xE000_E020, .secure));
    try std.testing.expectEqual(@as(?bank.Route, null), bank.route(0xE002_E00C, .secure));
}

test "a bank hands out the timer for each view" {
    var b = bank.Bank{};
    b.of(.non_secure).rvr = 7;
    try std.testing.expectEqual(@as(u32, 7), b.non_secure.rvr);
    try std.testing.expectEqual(@as(u32, 0), b.of(.secure).rvr);
}
