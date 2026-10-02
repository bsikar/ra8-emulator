//! A seam test for RA8EMU-54: what the module manager leans on when a
//! module strays. An unprivileged store outside the module's MPU regions
//! enters MemManage with the store's own address stacked and MMFAR
//! naming the target, and a privileged handler can abandon the module by
//! returning to a kernel recovery point instead of to the module.
//!
//! The store itself still lands in the RAM underneath (src/core/mpu_guard.zig
//! says why), so this checks the fault and the recovery, not the RAM.

const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const mpu = ra8.periph.mpu;
const mpu_guard = ra8.core.mpu_guard;
const Engine = ra8.core.engine.Engine;
const Nvic = ra8.periph.nvic.Nvic;
const Watch = ra8.core.session.Watch;

/// The module's code, the kernel's recovery point, its stack, a span only
/// privileged code may touch, and the vector table with its handlers.
const layout = struct {
    const module: u32 = memmap.sram_base;
    const recovery: u32 = memmap.sram_base + 0x100;
    const stack: u32 = memmap.sram_base + 0x4F00;
    const kernel_only: u32 = memmap.sram_base + 0x5000;
    const table: u32 = memmap.sram_base + 0x6000;
    const handlers: u32 = memmap.sram_base + 0x7000;
};

const memmanage: u32 = 4;
const memfaultena: u32 = 1 << 16;
/// CFSR.MMARVALID with CFSR.DACCVIOL.
const data_violation: u32 = 0x82;

/// `str r2, [r1]; movs r5, #1; b .`: the stray store, then a marker the
/// module only reaches if it is resumed.
const module_code = [_]u8{ 0x0A, 0x60, 0x01, 0x25, 0xFE, 0xE7 };
/// `movs r4, #0x77; b .`, where the kernel picks up.
const recovery_code = [_]u8{ 0x77, 0x24, 0xFE, 0xE7 };
/// `movs r0, #0; msr control, r0; str r3, [sp, #24]; bx lr`: drop back to
/// privileged, point the stacked return address at the recovery point
/// held in r3, and return.
const kill_handler = [_]u8{ 0x00, 0x20, 0x80, 0xF3, 0x14, 0x88, 0x06, 0x93, 0x70, 0x47 };

fn region(base: u32, limit: u32, attributes: u32) mpu.Region {
    return mpu.Region.fromPair(base | attributes, (limit & mpu.field.address) | mpu.field.rlar_enable);
}

const Bench = struct {
    core: Engine,
    unit: mpu.Mpu,
    guard: mpu_guard.Guard,

    fn open(self: *Bench) !void {
        self.core = try Engine.open();
        errdefer self.core.close();
        try self.core.mapBoardRam();
        var number: u32 = 0;
        while (number < 16) : (number += 1) {
            try self.core.writeWord(layout.table + 4 * number, layout.handlers + 0x10 * number + 1);
            try self.core.writeWord(layout.handlers + 0x10 * number, 0xE7FE_E7FE);
        }
        try self.core.write(layout.handlers + 0x10 * memmanage, &kill_handler);
        try self.core.writeWord(memmap.scb.vtor, layout.table);
        try self.core.writeWord(memmap.scb.shcsr, memfaultena);
        try self.core.write(layout.module, &module_code);
        try self.core.write(layout.recovery, &recovery_code);
        self.unit = mpu.Mpu.init();
        self.guard = mpu_guard.Guard.init();
        const open_to_all = mpu.field.rbar_ap_unprivileged;
        self.unit.table[0] = region(layout.module, layout.kernel_only - 1, open_to_all);
        self.unit.table[1] = region(layout.kernel_only, layout.kernel_only + 0x1F, 0);
        self.unit.table[2] = region(layout.table, layout.table + 0x2FFF, open_to_all);
        self.unit.ctrl = mpu.field.ctrl_enable;
        try self.core.attachRegions(&self.unit, &self.guard);
        self.guard.follow(self.core.handle, true);
        try self.core.setRegister(.sp, layout.stack);
        try self.core.setRegister(.control, 1);
        try self.core.setRegister(.r1, layout.kernel_only);
        try self.core.setRegister(.r2, 0x5A);
        try self.core.setRegister(.r3, layout.recovery);
    }

    fn close(self: *Bench) void {
        self.guard.disarm(self.core.handle);
        self.core.close();
    }

    fn run(self: *Bench, budget: u32) !?ra8.core.engine.Fault {
        var unit = Nvic{};
        var watch: Watch = .{};
        return self.core.run(layout.module, budget, .{
            .interrupts = &unit,
            .protection = &self.guard,
            .watch = &watch,
        });
    }
};

test "a module's stray store enters MemManage with the store stacked and MMFAR set" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();
    try bench.core.write(layout.handlers + 0x10 * memmanage, &[_]u8{ 0xFE, 0xE7 });
    try std.testing.expect(try bench.run(40) == null);
    try std.testing.expectEqual(memmanage, (try bench.core.register(.xpsr)) & 0x1FF);
    try std.testing.expectEqual(data_violation, try bench.core.readWord(memmap.scb.cfsr));
    try std.testing.expectEqual(layout.kernel_only, try bench.core.readWord(memmap.scb.mmfar));
    const frame = try bench.core.register(.sp);
    try std.testing.expectEqual(layout.module, try bench.core.readWord(frame + 24));
}

test "the handler abandons the module and the kernel carries on privileged" {
    var bench: Bench = undefined;
    try bench.open();
    defer bench.close();
    try std.testing.expect(try bench.run(60) == null);
    try std.testing.expectEqual(layout.recovery + 2, try bench.core.register(.pc));
    try std.testing.expectEqual(@as(u32, 0x77), try bench.core.register(.r4));
    try std.testing.expectEqual(@as(u32, 0), try bench.core.register(.r5));
    try std.testing.expectEqual(@as(u32, 0), (try bench.core.register(.xpsr)) & 0x1FF);
    try std.testing.expectEqual(@as(u32, 0), (try bench.core.register(.control)) & 1);
}
