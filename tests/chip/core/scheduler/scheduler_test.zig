//! Scalar validity and event wiring used by both execution adapters.
const std = @import("std");
const ra8 = @import("ra8");
const scheduler = ra8.chip.core.scheduler;
const ram = @import("../cpu/exception/ram.zig");

test "grid strict scheduler rejects impossible offsets and wraps and closes once" {
    var saved: scheduler.State = .{};
    saved.open(9, 100);
    saved.advance(9, 4);
    saved.endCpu0(false, false);
    try std.testing.expect(saved.valid());
    saved.next();
    try std.testing.expectEqual(@as(u64, 1), saved.at.r);
    try std.testing.expectEqual(@as(u64, 104), saved.base[0]);
    saved.stretch = .{ .full = 1, .carry = 2 };
    try std.testing.expect(!saved.valid());
    saved.stretch = .{ .full = 2, .carry = 2 };
    saved.base[0] = 0xffffffffffffffff;
    saved.lengths[0] = 1;
    try std.testing.expect(!saved.valid());
}

test "grid strict both cores send SEV through the scheduler wiring" {
    var a: ram.Ram = .{};
    var b: ram.Ram = .{};
    var cpu0 = try ram.boot(&a);
    var cpu1 = try ram.boot(&b);
    scheduler.pairEvents(&cpu0, &cpu1);
    a.putHalf(ram.code, 0xbf40);
    b.putHalf(ram.code, 0xbf40);
    try std.testing.expect(cpu0.step() == null);
    try std.testing.expect(cpu1.event);
    cpu0.event = false;
    try std.testing.expect(cpu1.step() == null);
    try std.testing.expect(cpu0.event);
}
