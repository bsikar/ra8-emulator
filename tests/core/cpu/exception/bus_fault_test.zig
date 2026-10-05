//! Covers src/core/cpu/exception/bus_fault.zig through Cpu.step: a load or
//! store the bus refuses is the precise BusFault when the run records
//! refusals, escalated to HardFault when BusFault is off, and a stop when
//! the run records nothing.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const memmap = ra8.core.memmap;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Stop = ra8.core.cpu.cpu.Stop;
const Profile = ra8.core.cpu.decode.profile.Profile;

const bus_handler: u32 = fixture.base + 0x1C0;
const hard_handler: u32 = fixture.base + 0x1E0;
const busfaultena: u32 = 1 << 17;
const preciserr: u32 = 1 << 9;
const bfarvalid: u32 = 1 << 15;
const forced: u32 = 1 << 30;
const hole: u32 = 0x6000_0010;
const str_r1_r0: u16 = 0x6001;
const ldr_r1_r0: u16 = 0x6801;
const profiles = [_]Profile{ Profile.m85, Profile.m33 };

/// `instr` at the reset PC with r0 = `hole`, r1 = 0xCAFE_F00D, refusals
/// recorded into `miss` when it is set.
fn bootWith(ram: *fixture.Ram, profile: Profile, instr: u16, miss: ?*u32) !Cpu {
    ram.putWord(fixture.base + 3 * 4, hard_handler | 1);
    ram.putWord(fixture.base + 5 * 4, bus_handler | 1);
    ram.putHalf(fixture.code, instr);
    var cpu = try fixture.boot(ram);
    cpu.profile = profile;
    cpu.bus.miss = miss;
    cpu.regs.low[0] = hole;
    cpu.regs.low[1] = 0xCAFE_F00D;
    return cpu;
}

fn ipsr(cpu: *const Cpu) u32 {
    return cpu.regs.xpsr & 0x1FF;
}

/// One refused access on both cores, BusFault enabled or not.
fn expectTaken(instr: u16, enabled: bool) !void {
    for (profiles) |profile| {
        var ram: fixture.Ram = .{};
        if (enabled) ram.putWord(memmap.scb.shcsr, busfaultena);
        var miss: u32 = 0;
        var cpu = try bootWith(&ram, profile, instr, &miss);
        try std.testing.expectEqual(@as(?Stop, null), cpu.step());
        try std.testing.expectEqual(if (enabled) bus_handler else hard_handler, cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, if (enabled) 5 else 3), ipsr(&cpu));
        try std.testing.expectEqual(preciserr | bfarvalid, ram.word(memmap.scb.cfsr));
        try std.testing.expectEqual(hole, ram.word(memmap.scb.bfar));
        try std.testing.expectEqual(if (enabled) 0 else forced, ram.word(memmap.scb.hfsr));
        // The faulting instruction is the stacked return address.
        try std.testing.expectEqual(fixture.code, ram.word(fixture.msp_top - 8));
        try std.testing.expectEqual(@as(u32, 0xCAFE_F00D), cpu.regs.low[1]);
    }
}

test "a refused store is a precise BusFault with BFAR" {
    try expectTaken(str_r1_r0, true);
}

test "a refused load is a precise BusFault and leaves its destination" {
    try expectTaken(ldr_r1_r0, true);
}

test "a refused access escalates to HardFault FORCED when BusFault is off" {
    try expectTaken(str_r1_r0, false);
}

test "a run that records no refusals stops on the bus fault" {
    for (profiles) |profile| {
        var ram: fixture.Ram = .{};
        ram.putWord(memmap.scb.shcsr, busfaultena);
        var cpu = try bootWith(&ram, profile, str_r1_r0, null);
        try std.testing.expectEqual(@as(?Stop, .{ .bus_fault = fixture.code }), cpu.step());
        try std.testing.expectEqual(@as(u32, 0), ram.word(memmap.scb.cfsr));
    }
}
