//! Tests for src/session/zig/drive.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const zig_core = ra8.session.step_hook.zig.core;
const zig_drive = ra8.session.step_hook.zig.drive;
const Machine = ra8.session.stop_machine.Machine;
const QuietSource = ra8.chip.core.cpu.exception.quiet_source.QuietSource;
const Fake = @import("../../chip/core/cpu/exception/fake_source.zig").Fake;
const exception_ram = @import("../../chip/core/cpu/exception/ram.zig");

const PendBus = struct {
    ram: *exception_ram.Ram,
    fake: *Fake,
    fn view(self: *PendBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }
    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *PendBus = @ptrCast(@alignCast(ctx));
        try self.ram.view().read(address, into);
    }
    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *PendBus = @ptrCast(@alignCast(ctx));
        try self.ram.view().write(address, bytes);
        if (address == exception_ram.base + 0x80) self.fake.pending = .{ .number = 11, .priority = 0 };
    }
};

test "grid repair G3 canonical target polls even when host budget ends on STR" {
    for ([_]u64{ 1, 2, 13 }) |budget| {
        var memory: exception_ram.Ram = .{};
        memory.putHalf(exception_ram.code, 0x6001);
        memory.putHalf(exception_ram.handler, 0x3301);
        var cpu = try exception_ram.boot(&memory);
        cpu.regs.primask = 0;
        cpu.regs.low[0] = exception_ram.base + 0x80;
        var fake: Fake = .{};
        var pending: PendBus = .{ .ram = &memory, .fake = &fake };
        cpu.bus = pending.view();
        cpu.source = fake.source();
        var machine: Machine = .{};
        var saved: ra8.chip.core.scheduler.State = .{};
        var live: ra8.session.step_hook.zig.session.ZigSession = .{
            .core = .{ .cpu = &cpu },
            .machine = &machine,
            .budget = budget,
            .boundary = .{ .context = &saved, .tickFn = noTick, .chunk = 64, .saved = &saved },
        };
        const ended = try live.runToCount(0, 1);
        try std.testing.expect(ended == .stop and ended.stop == .stepped);
        std.debug.print("CHECK=G3 budget={d} PC={x} slots={d} gap={s}\n", .{ budget, cpu.regs.pc, cpu.slots, @tagName(saved.at.gap) });
        try std.testing.expectEqual(exception_ram.handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u64, 1), cpu.slots);
        try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[3]);
        try std.testing.expectEqual(@as(u32, 1), saved.stretch.carry);
    }
}

fn noTick(_: *anyopaque, _: u32) anyerror!void {}

test "grid repair G4 pending exception step stops at handler without an instruction" {
    for ([_]bool{ false, true }) |served| {
        var memory: exception_ram.Ram = .{};
        memory.putHalf(exception_ram.code, 0xbf00);
        memory.putHalf(exception_ram.handler, 0x3301);
        var cpu = try exception_ram.boot(&memory);
        cpu.regs.primask = 0;
        var fake: Fake = .{ .pending = .{ .number = 11, .priority = 0 } };
        cpu.source = fake.source();
        var machine: Machine = .{};
        var saved: ra8.chip.core.scheduler.State = .{};
        var live: ra8.session.step_hook.zig.session.ZigSession = .{
            .core = .{ .cpu = &cpu },
            .machine = &machine,
            .budget = 64,
            .boundary = if (served) .{ .context = &saved, .tickFn = noTick, .chunk = 64, .saved = &saved } else null,
        };
        const ended = try live.go(.step);
        std.debug.print("CHECK=G4 served={} PC={x} slots={d} r3={d}\n", .{ served, cpu.regs.pc, cpu.slots, cpu.regs.low[3] });
        try std.testing.expect(ended == .stop and ended.stop == .stepped);
        try std.testing.expectEqual(exception_ram.handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u64, 0), cpu.slots);
        try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[3]);
    }
}

fn pendOnTick(ctx: *anyopaque, _: u32) anyerror!void {
    const fake: *Fake = @ptrCast(@alignCast(ctx));
    fake.pending = .{ .number = 11, .priority = 0 };
}

// WFI costs its own slot, so the step's target is met asleep. The step ends
// at the next awake canonical position: after the wake poll, at the handler.
test "grid repair G4 served step over WFI ends at the wake poll before the handler runs" {
    var memory: exception_ram.Ram = .{};
    memory.putHalf(exception_ram.code, 0xbf30);
    memory.putHalf(exception_ram.code + 2, 0xe7fd);
    memory.putHalf(exception_ram.handler, 0x3301);
    var cpu = try exception_ram.boot(&memory);
    cpu.regs.primask = 0;
    var fake: Fake = .{};
    cpu.source = fake.source();
    var machine: Machine = .{};
    var saved: ra8.chip.core.scheduler.State = .{};
    var live: ra8.session.step_hook.zig.session.ZigSession = .{
        .core = .{ .cpu = &cpu },
        .machine = &machine,
        .budget = 256,
        .boundary = .{ .context = &fake, .tickFn = pendOnTick, .chunk = 64, .saved = &saved },
    };
    const ended = try live.go(.step);
    std.debug.print("CHECK=G4 wake PC={x} slots={d} r3={d} r={d} gap={s}\n", .{ cpu.regs.pc, cpu.slots, cpu.regs.low[3], saved.at.r, @tagName(saved.at.gap) });
    try std.testing.expect(ended == .stop and ended.stop == .stepped);
    try std.testing.expectEqual(exception_ram.handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u64, 1), cpu.slots);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[3]);
    try std.testing.expect(cpu.waiting == null);
    try std.testing.expectEqual(@as(u64, 1), saved.at.r);
    try std.testing.expectEqual(ra8.chip.core.scheduler.position.Gap.polled, saved.at.gap);
}

test "grid strict armed WFI agrees with quiet and resume checks a newly polled handler" {
    for ([_]bool{ false, true }) |armed| {
        var memory: exception_ram.Ram = .{};
        memory.putHalf(exception_ram.code, 0xbf30);
        memory.putHalf(exception_ram.code + 2, 0xe7fd);
        memory.putHalf(exception_ram.handler, 0x3301);
        var cpu = try exception_ram.boot(&memory);
        var fake: Fake = .{};
        cpu.source = fake.source();
        var machine: Machine = .{};
        machine.begin();
        if (armed) _ = try machine.addBreak(.{ .address = 0xffffff00 });
        const core: zig_core.ZigCore = .{ .cpu = &cpu };
        var slots: u64 = 0;
        try std.testing.expect(zig_drive.runCounted(core, &machine, 1000, null, null, &slots) == .count);
        try std.testing.expectEqual(@as(u64, 1), slots);
        try std.testing.expectEqual(exception_ram.code + 2, cpu.regs.pc);
        try std.testing.expect(cpu.waiting != null);
        const id = try machine.addBreak(.{ .address = exception_ram.handler });
        machine.proceed();
        fake.pending = .{ .number = 11, .priority = 0 };
        const ended = zig_drive.run(core, &machine, 100);
        try std.testing.expectEqual(id, ended.stop.breakpoint);
        try std.testing.expectEqual(@as(u64, 1), cpu.slots);
        try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[3]);
        try std.testing.expect(cpu.waiting == null);
    }
}

test "grid strict armed and quiet synchronous entries charge slots without retirement" {
    for ([_]bool{ false, true }) |armed| {
        var memory: exception_ram.Ram = .{};
        memory.putWord(exception_ram.base + 12, exception_ram.handler | 1);
        memory.putHalf(exception_ram.code, 0xde00);
        memory.putHalf(exception_ram.handler, 0xe7fe);
        var cpu = try exception_ram.boot(&memory);
        var machine: Machine = .{};
        machine.begin();
        if (armed) _ = try machine.addBreak(.{ .address = 0xffffff00 });
        var slots: u64 = 0;
        try std.testing.expect(zig_drive.runCounted(.{ .cpu = &cpu }, &machine, 1, null, null, &slots) == .count);
        try std.testing.expectEqual(@as(u64, 1), slots);
        try std.testing.expectEqual(@as(u64, 0), cpu.retired);
        try std.testing.expectEqual(@as(u64, 1), cpu.sync_entries);
    }
}

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
    var r: Ram = .{ .bytes = @as([64]u8, @splat(0)) };
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

test "a quiet run of a branch to itself retires exactly the instructions asked for" {
    var memory = ram();
    memory.bytes[0x08] = 0xFE; // b . (0xE7FE)
    memory.bytes[0x09] = 0xE7;
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine: Machine = .{};
    machine.begin();
    var retired: u64 = 0;
    const ended = zig_drive.runCounted(core, &machine, 1000, null, null, &retired);
    try std.testing.expectEqual(zig_drive.Ended.count, ended);
    try std.testing.expectEqual(@as(u64, 1000), retired);
    try std.testing.expectEqual(@as(u32, 0x08), core.register(.pc));
}

test "a quiet core asleep consumes no slots in the time-only tail" {
    var memory = ram();
    memory.bytes[0x08] = 0x30; // wfi (0xBF30)
    memory.bytes[0x09] = 0xBF;
    memory.bytes[0x0A] = 0xFD; // b 0x08 (0xE7FD)
    memory.bytes[0x0B] = 0xE7;
    var fake: Fake = .{};
    var cpu: Cpu = .{ .bus = memory.view(), .source = fake.source() };
    try cpu.reset(0);
    const core: zig_core.ZigCore = .{ .cpu = &cpu };
    var machine: Machine = .{};
    machine.begin();
    var retired: u64 = 0;
    const ended = zig_drive.runCounted(core, &machine, 1000, null, null, &retired);
    try std.testing.expectEqual(zig_drive.Ended.count, ended);
    try std.testing.expectEqual(@as(u64, 1), retired);
    try std.testing.expect(cpu.waiting != null);
    try std.testing.expect(cpu.retired < 4);
}
