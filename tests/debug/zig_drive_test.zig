//! Tests for src/debug/zig_drive.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const zig_core = ra8.core.step_hook.zig_core;
const zig_drive = ra8.core.step_hook.zig_drive;
const Machine = ra8.core.stop_machine.Machine;
const QuietSource = ra8.core.cpu.exception.quiet_source.QuietSource;
const Fake = @import("../core/cpu/exception/fake_source.zig").Fake;

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

// sp 0x40, reset 0x09 ; 0x08 bf00 nop ; 0x0A f3af 8000 nop.w ; 0x0E bf00 nop ; 0x10 ba80 (unallocated)
fn ram() Ram {
    var r: Ram = .{ .bytes = [_]u8{0} ** 64 };
    const image = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
        0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xBF,
        0x80, 0xBA,
    };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

test "the event names the instruction's address, width and stack pointer" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    const first = zig_drive.event(core);
    try std.testing.expectEqual(@as(u32, 0x08), first.pc);
    try std.testing.expectEqual(@as(u8, 2), first.size);
    try std.testing.expectEqual(@as(u32, 0x40), first.sp);
    try std.testing.expect(!first.call);
    cpu.regs.pc = 0x0A;
    try std.testing.expectEqual(@as(u8, 4), zig_drive.event(core).size);
}

test "a break stops the core before the instruction on it runs" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    const id = try machine.breaks.add(.{ .address = 0x0E });
    machine.begin();
    const ended = zig_drive.run(core, &machine, 100);
    try std.testing.expectEqual(id, ended.stop.breakpoint);
    try std.testing.expectEqual(@as(u32, 0x0E), core.register(.pc));
    try std.testing.expectEqual(@as(u64, 2), cpu.retired);
}

test "a step runs one instruction, wide ones included" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    cpu.regs.pc = 0x0A;
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    machine.step();
    try std.testing.expect(zig_drive.run(core, &machine, 100).stop == .stepped);
    try std.testing.expectEqual(@as(u32, 0x0E), core.register(.pc));
}

test "with nothing to stop on, the run ends on the core's own stop" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    machine.begin();
    try std.testing.expect(zig_drive.run(core, &machine, 2) == .count);
    try std.testing.expectEqual(@as(u32, 0x10), zig_drive.run(core, &machine, 100).core.unknown.address);
}

test "a quiet run still stops for a halt or a break armed between runs" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    machine.begin();
    try std.testing.expect(machine.quiet());
    try std.testing.expect(zig_drive.run(core, &machine, 1) == .count);
    machine.requestHalt();
    try std.testing.expect(zig_drive.run(core, &machine, 100).stop == .halt_requested);
    try std.testing.expectEqual(@as(u32, 0x0A), core.register(.pc));
    const id = try machine.breaks.add(.{ .address = 0x0E });
    machine.proceed();
    try std.testing.expectEqual(id, zig_drive.run(core, &machine, 100).stop.breakpoint);
    try std.testing.expectEqual(@as(u64, 2), cpu.retired);
}

test "a run chunk starts by forgetting the interrupt poll's last answer" {
    var memory = ram();
    var fake: Fake = .{};
    var quiet: QuietSource = .{ .inner = fake.source(), .memory = memory.view() };
    var cpu: Cpu = .{ .bus = quiet.bus(), .source = quiet.source(), .quiet = &quiet };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine = Machine{};
    machine.begin();
    try std.testing.expect(zig_drive.run(core, &machine, 1) == .count);
    try std.testing.expect(quiet.hushed);
    var retired: u64 = 0;
    try std.testing.expect(zig_drive.runCounted(core, &machine, 0, null, null, &retired) == .count);
    try std.testing.expect(!quiet.hushed);
}
