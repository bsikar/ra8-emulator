//! Covers src/chip/core/cpu/systick_cut.zig: a store that arms SysTick ends the
//! stretch in flight (RA8EMU-464).
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cut = ra8.chip.core.cpu.cpu.systick_cut.Cut;
const Pending = ra8.chip.core.cpu.cpu.systick_cut.Pending;
const Clocks = ra8.chip.periph.clocks.Clocks;
const Words = ra8.chip.periph.clocks.Words;

/// The two SysTick windows, the normal one and the Non-secure alias.
const Ram = struct {
    const normal: u32 = 0xE000_E000;
    const alias: u32 = 0xE002_E000;
    lo: [0x40]u8 = @splat(0),
    hi: [0x40]u8 = @splat(0),

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn slot(self: *Ram, address: u32, len: usize) bus.Error![]u8 {
        if (address >= normal and address - normal + len <= self.lo.len) return self.lo[address - normal ..][0..len];
        if (address >= alias and address - alias + len <= self.hi.len) return self.hi[address - alias ..][0..len];
        return bus.Error.Unmapped;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(into, try self.slot(address, into.len));
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        @memcpy(try self.slot(address, from.len), from);
    }
};

fn word(value: u32) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    return bytes;
}

/// Store through the cut, then into RAM, in the order the board bus does.
fn store(cut: *Cut, ram: *Ram, address: u32, value: u32) !void {
    const bytes = word(value);
    try cut.see(ram.view(), address, &bytes);
    try ram.view().write(address, &bytes);
}

const csr = (Words{}).csr;
const rvr = (Words{}).rvr;
const cvr = (Words{}).cvr;

test "cut tail zero old reload remains legal with either ENABLE state" {
    for ([_]u8{ 0, 1, 2, 3 }) |control| {
        try std.testing.expect((Pending{ .old_control = control }).valid());
        try std.testing.expectEqual(control & 1 != 0, (Pending{ .old_control = control, .old_reload = 9 }).valid());
        var ram: Ram = .{};
        var clock: Clocks = .{};
        var cut: Cut = .{ .clocks = .{ &clock, null } };
        try ram.view().write(csr, &word(control));
        try store(&cut, &ram, rvr, 9);
        if (control & 1 == 0) try store(&cut, &ram, csr, control | 1);
        const pending = cut.takePending().?;
        try std.testing.expect(pending.valid());
        try std.testing.expectEqual(@as(u32, 0), pending.old_reload);
        try std.testing.expectEqual(control, pending.old_control);
    }
}

test "cut tail CVR before or after rearm retains the first counter" {
    for ([_]bool{ false, true }) |counter_first| {
        var ram: Ram = .{};
        var clock: Clocks = .{};
        var slot: u64 = 4;
        var cut: Cut = .{ .clocks = .{ &clock, null }, .instruction = &slot };
        try ram.view().write(csr, &word(5));
        try ram.view().write(rvr, &word(9));
        try ram.view().write(cvr, &word(8));
        if (counter_first) try store(&cut, &ram, cvr, 0);
        try store(&cut, &ram, csr, 7);
        try store(&cut, &ram, rvr, 4);
        if (!counter_first) try store(&cut, &ram, cvr, 0);
        const pending = cut.takePending().?;
        try std.testing.expect(pending.valid());
        try std.testing.expect(pending.current_written);
        try std.testing.expectEqual(@as(u32, 8), pending.old_current);
        try std.testing.expectEqual(@as(u8, 1), pending.old_control);
        slot += 1;
        try store(&cut, &ram, rvr, 6);
        const next = cut.takePending().?;
        try std.testing.expect(!next.current_written);
        try std.testing.expectEqual(@as(u32, 0), next.old_current);
    }
}

test "starting the counter with a reload staged cuts the stretch once" {
    var ram: Ram = .{};
    var clock: Clocks = .{};
    var cut: Cut = .{ .clocks = .{ &clock, null } };
    try store(&cut, &ram, rvr, 8399);
    try std.testing.expect(!cut.fired);
    try store(&cut, &ram, csr, 0x7);
    try std.testing.expect(cut.fired);
    try std.testing.expectEqual(@as(u64, 1), clock.rearms);
    try std.testing.expectEqual(Pending.Bank.secure, cut.pending.?.bank);
    try std.testing.expectEqual(@as(u32, 0), cut.pending.?.old_reload);
    try std.testing.expect(cut.take());
    try std.testing.expect(!cut.take());
    try std.testing.expect(!clock.restart);
}

test "a running counter cuts only when its reload moves" {
    var ram: Ram = .{};
    var clock: Clocks = .{};
    var cut: Cut = .{ .clocks = .{ &clock, null } };
    try store(&cut, &ram, rvr, 8399);
    try store(&cut, &ram, csr, 0x7);
    _ = cut.take();
    try store(&cut, &ram, rvr, 8399);
    try std.testing.expect(!cut.fired);
    try store(&cut, &ram, rvr, 4199);
    try std.testing.expectEqual(@as(u32, 8399), cut.pending.?.old_reload);
    try std.testing.expect(cut.take());
}

test "the Non-secure timer is watched at its own words" {
    var ram: Ram = .{};
    var secure: Clocks = .{};
    var non_secure: Clocks = .{ .words = Words.non_secure };
    var cut: Cut = .{ .clocks = .{ &secure, &non_secure } };
    try store(&cut, &ram, Words.non_secure.rvr, 999);
    try store(&cut, &ram, Words.non_secure.csr, 0x7);
    try std.testing.expect(cut.fired);
    try std.testing.expectEqual(@as(u64, 0), secure.rearms);
    try std.testing.expectEqual(@as(u64, 1), non_secure.rearms);
    try std.testing.expectEqual(Pending.Bank.non_secure, cut.pending.?.bank);
}

test "a narrow store never cuts" {
    var ram: Ram = .{};
    var clock: Clocks = .{};
    var cut: Cut = .{ .clocks = .{ &clock, null } };
    try store(&cut, &ram, rvr, 8399);
    const half = [_]u8{ 0x07, 0x00 };
    try cut.see(ram.view(), csr, &half);
    try std.testing.expect(!cut.fired);
}

test "multiple stores retain the first state of their instruction" {
    var ram: Ram = .{};
    var clock: Clocks = .{};
    var slot: u64 = 2;
    var cut: Cut = .{ .clocks = .{ &clock, null }, .instruction = &slot };
    try store(&cut, &ram, rvr, 9);
    try store(&cut, &ram, csr, 7);
    try store(&cut, &ram, rvr, 4);
    try std.testing.expectEqual(@as(u32, 0), cut.pending.?.old_reload);
    try std.testing.expectEqual(@as(u8, 0), cut.pending.?.old_control);
    try std.testing.expectEqual(@as(u64, 2), clock.rearms);
    _ = cut.takePending();

    slot += 1;
    try store(&cut, &ram, rvr, 9);
    try store(&cut, &ram, csr, 5);
    _ = cut.takePending();
    slot += 1;
    try store(&cut, &ram, csr, 7);
    try store(&cut, &ram, rvr, 4);
    try std.testing.expectEqual(@as(u32, 9), cut.pending.?.old_reload);
    try std.testing.expectEqual(@as(u8, 5 & 3), cut.pending.?.old_control);
}
