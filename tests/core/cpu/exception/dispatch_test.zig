//! Covers src/core/cpu/exception/dispatch.zig, through `Cpu.run`.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const Fake = @import("fake_source.zig").Fake;

const pendsv: u9 = 14;
const systick: u9 = 15;
const nop: u16 = 0xBF00;
const bx_lr: u16 = 0x4770;

/// Thread code is a run of NOPs; PendSV and SysTick both go to a handler
/// that is a NOP and BX LR.
fn setup(ram: *fixture.Ram, fake: *Fake) !ra8.core.cpu.cpu.Cpu {
    var at = fixture.code;
    while (at < fixture.code + 0x40) : (at += 2) ram.putHalf(at, nop);
    ram.putHalf(fixture.handler, nop);
    ram.putHalf(fixture.handler + 2, bx_lr);
    ram.putWord(fixture.base + 4 * @as(u32, pendsv), fixture.handler | 1);
    ram.putWord(fixture.base + 4 * @as(u32, systick), fixture.handler | 1);
    var cpu = try fixture.boot(ram);
    cpu.source = fake.source();
    return cpu;
}

test "a pending exception is taken before the next instruction and returns to it" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake);
    _ = cpu.run(2);
    fake.pending = .{ .number = pendsv, .priority = 0xFF };
    _ = cpu.run(1); // taken, then the handler's NOP
    try std.testing.expectEqual(fixture.handler + 2, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, pendsv), cpu.regs.xpsr & 0x1FF);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
    _ = cpu.run(1); // BX LR
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(@as(?u9, pendsv), fake.last_returned);
    try std.testing.expectEqual(@as(usize, 0), cpu.active.depth);
}

test "PRIMASK holds a pending exception until it clears" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = 0 } };
    var cpu = try setup(&ram, &fake);
    cpu.regs.primask = 1;
    _ = cpu.run(3);
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
    cpu.regs.primask = 0;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
}

test "BASEPRI holds what is no more urgent than it" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = systick, .priority = 0x40 } };
    var cpu = try setup(&ram, &fake);
    cpu.regs.basepri = 0x40;
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
    cpu.regs.basepri = 0x80;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
}

test "a running handler is preempted only by something more urgent" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = 0x80 } };
    var cpu = try setup(&ram, &fake);
    _ = cpu.run(1);
    fake.pending = .{ .number = systick, .priority = 0x80 };
    cpu.regs.pc = fixture.handler; // stay on the handler's NOP
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 1), cpu.active.depth);
    fake.pending = .{ .number = systick, .priority = 0x40 };
    cpu.regs.pc = fixture.handler;
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(usize, 2), cpu.active.depth);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF1), cpu.regs.lr);
}

test "a pend with no vector is left pending" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = 20, .priority = 0 } };
    var cpu = try setup(&ram, &fake);
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
    try std.testing.expectEqual(fixture.code + 4, cpu.regs.pc);
}

test "SVC runs at the priority SHPR2 gives it and leaves the stack on return" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var cpu = try setup(&ram, &fake);
    ram.putWord(0xE000_ED1C, 0x6000_0000);
    ram.putHalf(fixture.code, 0xDF00);
    _ = cpu.run(1);
    try std.testing.expectEqual(@as(u8, 0x60), cpu.active.running().?.priority);
    _ = cpu.run(2);
    try std.testing.expectEqual(@as(usize, 0), cpu.active.depth);
    try std.testing.expectEqual(@as(?u9, 11), fake.last_returned);
}

test "a step on its own never takes an asynchronous exception" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = .{ .number = pendsv, .priority = 0 } };
    var cpu = try setup(&ram, &fake);
    _ = cpu.step();
    try std.testing.expectEqual(@as(u32, 0), fake.taken);
}
