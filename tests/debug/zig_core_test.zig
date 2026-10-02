//! Tests for src/debug/zig_core.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const zig_core = ra8.core.step_hook.zig_core;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

// sp 0x00000040, reset 0x09 ; bf00 nop ; bf00 nop ; bf00 nop ; de00 udf #0
fn ram() Ram {
    var r: Ram = .{ .bytes = [_]u8{0} ** 64 };
    const image = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
        0x00, 0xBF, 0x00, 0xBF, 0x00, 0xBF, 0x00, 0xDE,
    };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

test "registers read and write by the engine's names" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try std.testing.expectEqual(@as(u32, 0x08), core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x40), core.register(.sp));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), core.register(.lr));
    core.setRegister(.r7, 0x1234);
    core.setRegister(.r12, 0x5678);
    try std.testing.expectEqual(@as(u32, 0x1234), core.register(.r7));
    try std.testing.expectEqual(@as(u32, 0x5678), cpu.regs.low[12]);
}

test "memory goes through the core's bus" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try core.write(0x30, &[_]u8{ 0xEF, 0xBE, 0xAD, 0xDE });
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try core.readWord(0x30));
    try std.testing.expectError(bus.Error.Unmapped, core.readWord(0x100));
}

test "a step retires one instruction" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), core.step());
    try std.testing.expectEqual(@as(u32, 0x0A), core.register(.pc));
    try std.testing.expectEqual(@as(u64, 1), cpu.retired);
}

test "a run stops on a breakpoint and moves off it when continued" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    const breaks = [_]u32{ 0x0B, 0x0C };
    try std.testing.expectEqual(@as(u32, 0x0A), core.runUntil(&breaks, 100).breakpoint);
    try std.testing.expectEqual(@as(u32, 0x0C), core.runUntil(&breaks, 100).breakpoint);
}

test "a run reports the core's own stop and its count" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    try std.testing.expectEqual(zig_core.Stop.count, core.runUntil(&.{}, 2));
    const stopped = core.runUntil(&.{}, 100);
    try std.testing.expectEqual(@as(u32, 0x0E), stopped.core.unknown.address);
}
