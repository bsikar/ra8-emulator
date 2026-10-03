//! Covers src/core/cpu/exception/mem_manage.zig through Cpu.step: a load or
//! store the MPU refuses is turned away before memory and taken as
//! MemManage, or escalated to HardFault.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.core.memmap;
const bus = ra8.core.cpu.bus;
const mpu = ra8.periph.mpu;
const mpu_check = ra8.core.cpu.board_bus.mpu_check;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Stop = ra8.core.cpu.cpu.Stop;

const mem_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const memfaultena: u32 = 1 << 16;
const daccviol: u32 = 1 << 1;
const mmarvalid: u32 = 1 << 7;
const forced: u32 = 1 << 30;
const window: u32 = fixture.base + 0x200;
const before: u32 = 0x1234_5678;

/// The fixture's RAM behind the check, the way BoardBus asks it.
const Guarded = struct {
    ram: *fixture.Ram,
    check: *mpu_check.Check,

    fn view(self: *Guarded) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }
    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Guarded = @ptrCast(@alignCast(ctx));
        if (!self.check.allows(address, .load)) return bus.Error.Unmapped;
        return self.ram.view().read(address, into);
    }
    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Guarded = @ptrCast(@alignCast(ctx));
        if (!self.check.allows(address, .store)) return bus.Error.Unmapped;
        return self.ram.view().write(address, from);
    }
};

/// RAM read-write for everyone, with a privileged read-only window at
/// `window` (region 1 outranks region 0).
fn unitOf(ctrl: u32) mpu.Mpu {
    var unit = mpu.Mpu{};
    unit.table[0] = mpu.Region.fromPair(fixture.base | mpu.field.rbar_ap_unprivileged, ((fixture.base + 0x3FF) & mpu.field.address) | mpu.field.rlar_enable);
    unit.table[1] = mpu.Region.fromPair(window | mpu.field.rbar_ap_ro, ((window + 0x3F) & mpu.field.address) | mpu.field.rlar_enable);
    unit.ctrl = ctrl;
    return unit;
}

/// `instr` at the reset PC with r0 = `address`, r1 = 0xCAFE_F00D.
fn bootWith(ram: *fixture.Ram, guarded: *Guarded, instr: u16, address: u32) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 4 * 4, mem_handler | 1);
    ram.putHalf(fixture.code, instr);
    ram.putWord(window, before);
    var cpu = try fixture.boot(ram);
    cpu.bus = guarded.view();
    cpu.mpu = guarded.check;
    cpu.regs.low[0] = address;
    cpu.regs.low[1] = 0xCAFE_F00D;
    return cpu;
}

const str_r1_r0: u16 = 0x6001;
const ldr_r1_r0: u16 = 0x6801;

fn ipsr(cpu: *const Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

fn expectMemManage(ram: *fixture.Ram, cpu: *Cpu, at: u32) !void {
    try std.testing.expectEqual(mem_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 4), ipsr(cpu));
    try std.testing.expectEqual(daccviol | mmarvalid, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(at, ram.word(memmap.scb.mmfar));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.hfsr));
    // The faulting instruction is the stacked return address.
    try std.testing.expectEqual(fixture.code, ram.word(fixture.msp_top - 8));
}

test "a privileged store to a read-only region is MemManage and never lands" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = unitOf(mpu.field.ctrl_enable);
    var check: mpu_check.Check = .{ .unit = &unit };
    var guarded: Guarded = .{ .ram = &ram, .check = &check };
    var cpu = try bootWith(&ram, &guarded, str_r1_r0, window);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try expectMemManage(&ram, &cpu, window);
    try std.testing.expectEqual(before, ram.word(window));
}

test "the same store to the read-write region beside it goes ahead" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = unitOf(mpu.field.ctrl_enable);
    var check: mpu_check.Check = .{ .unit = &unit };
    var guarded: Guarded = .{ .ram = &ram, .check = &check };
    var cpu = try bootWith(&ram, &guarded, str_r1_r0, window + 0x40);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), ram.word(window + 0x40));
    try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
}

test "an unprivileged load from a privileged-only region is MemManage" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = unitOf(mpu.field.ctrl_enable);
    var check: mpu_check.Check = .{ .unit = &unit };
    var guarded: Guarded = .{ .ram = &ram, .check = &check };
    var cpu = try bootWith(&ram, &guarded, ldr_r1_r0, window);
    cpu.regs.control |= ra8.core.cpu.regs.control_bits.npriv;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try expectMemManage(&ram, &cpu, window);
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.low[1]);
}

test "the background: PRIVDEFENA lets privileged code through, not unprivileged" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = unitOf(mpu.field.ctrl_enable | mpu.field.ctrl_privdefena);
    unit.table[0] = .{};
    var check: mpu_check.Check = .{ .unit = &unit };
    var guarded: Guarded = .{ .ram = &ram, .check = &check };
    var cpu = try bootWith(&ram, &guarded, str_r1_r0, fixture.base + 0x100 + 0x80);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    unit.ctrl = mpu.field.ctrl_enable;
    var again = try bootWith(&ram, &guarded, str_r1_r0, fixture.base + 0x100 + 0x80);
    _ = &again;
    try std.testing.expectEqual(@as(?Stop, null), again.step());
    try std.testing.expectEqual(mem_handler, again.regs.pc);
}

test "with MEMFAULTENA clear the fault escalates to HardFault with FORCED" {
    var ram: fixture.Ram = .{};
    var unit = unitOf(mpu.field.ctrl_enable);
    var check: mpu_check.Check = .{ .unit = &unit };
    var guarded: Guarded = .{ .ram = &ram, .check = &check };
    var cpu = try bootWith(&ram, &guarded, str_r1_r0, window);
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(hard_handler, cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 3), ipsr(&cpu));
    try std.testing.expectEqual(forced, ram.word(memmap.scb.hfsr));
    try std.testing.expectEqual(daccviol | mmarvalid, ram.word(memmap.scb.cfsr));
    try std.testing.expectEqual(before, ram.word(window));
}

test "under FAULTMASK the MPU is off, unless HFNMIENA, which locks up" {
    var ram: fixture.Ram = .{};
    var unit = unitOf(mpu.field.ctrl_enable);
    var check: mpu_check.Check = .{ .unit = &unit };
    var guarded: Guarded = .{ .ram = &ram, .check = &check };
    var cpu = try bootWith(&ram, &guarded, str_r1_r0, window);
    cpu.regs.faultmask = 1;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), ram.word(window));
    unit.ctrl |= mpu.field.ctrl_hfnmiena;
    var locked = try bootWith(&ram, &guarded, str_r1_r0, window);
    locked.regs.faultmask = 1;
    try std.testing.expectEqual(@as(?Stop, .{ .bus_fault = fixture.code }), locked.step());
}

test "an M33 core (CPU1's profile) takes the same MemManage" {
    var ram: fixture.Ram = .{};
    ram.putWord(memmap.scb.shcsr, memfaultena);
    var unit = unitOf(mpu.field.ctrl_enable);
    var check: mpu_check.Check = .{ .unit = &unit };
    var guarded: Guarded = .{ .ram = &ram, .check = &check };
    var cpu = try bootWith(&ram, &guarded, str_r1_r0, window);
    cpu.profile = ra8.core.cpu.decode.profile.Profile.m33;
    try std.testing.expectEqual(@as(?Stop, null), cpu.step());
    try expectMemManage(&ram, &cpu, window);
}
