//! Tests for src/core/mpu_guard.zig, on a live engine: the privilege a store
//! is judged by comes from the core itself, and an execute-never region
//! refuses the fetch rather than the store.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const mpu = ra8.periph.mpu;
const mpu_guard = ra8.core.mpu_guard;
const Engine = ra8.core.engine.Engine;

/// Where each fixture lives in SRAM: the code and stack the test runs from,
/// a region kept to privileged code, and an execute-never one.
const layout = struct {
    const code: u32 = memmap.sram_base;
    const code_limit: u32 = memmap.sram_base + 0x1FFF;
    const privileged_only: u32 = memmap.sram_base + 0x2000;
    const execute_never: u32 = memmap.sram_base + 0x3000;
    const stack: u32 = memmap.sram_base + 0x1F00;
};

/// CONTROL.nPRIV, and an xPSR with the Thumb bit and an exception number in
/// IPSR, which is what handler mode is.
const status = struct {
    const npriv: u32 = 1;
    const thumb: u32 = 1 << 24;
    const in_handler: u32 = thumb | 3;
};

/// `str r2, [r1]` then `nop`, so the run has one store to make.
const one_store = [_]u8{ 0x0A, 0x60, 0x00, 0xBF };
/// `nop` twice, for a fetch out of the execute-never region.
const two_nops = [_]u8{ 0x00, 0xBF, 0x00, 0xBF };

const Fixture = struct {
    engine: Engine,
    unit: mpu.Mpu,
    guard: mpu_guard.Guard,

    /// An open engine with three regions programmed and the MPU enabled: the
    /// code span open to everyone, one privileged-only span, and one span
    /// unprivileged code may use but nobody may execute from.
    fn open(self: *Fixture) !void {
        self.engine = try Engine.open();
        errdefer self.engine.close();
        try self.engine.mapBoardRam();
        self.unit = mpu.Mpu.init();
        self.guard = mpu_guard.Guard.init();
        const open_to_all = mpu.field.rbar_ap_unprivileged;
        const never_run = mpu.field.rbar_ap_unprivileged | mpu.field.rbar_xn;
        self.unit.table[0] = region(layout.code, layout.code_limit, open_to_all);
        self.unit.table[1] = region(layout.privileged_only, layout.privileged_only + 0x1F, 0);
        self.unit.table[2] = region(layout.execute_never, layout.execute_never + 0x1F, never_run);
        self.unit.ctrl = mpu.field.ctrl_enable;
        try self.engine.attachRegions(&self.unit, &self.guard);
        self.guard.follow(self.engine.handle, true);
        try self.engine.setRegister(.sp, layout.stack);
    }

    fn close(self: *Fixture) void {
        self.guard.disarm(self.engine.handle);
        self.engine.close();
    }

    /// Run the one store at the bottom of the code span, aimed at `target`.
    fn store(self: *Fixture, target: u32) !void {
        try self.engine.write(layout.code, &one_store);
        try self.engine.setRegister(.r1, target);
        try self.engine.setRegister(.r2, 0x5A5A_5A5A);
        _ = try self.engine.runChunk(layout.code, 2, null);
    }
};

fn region(base: u32, limit: u32, attributes: u32) mpu.Region {
    return mpu.Region.fromPair(base | attributes, (limit & mpu.field.address) | mpu.field.rlar_enable);
}

test "an unprivileged store into a privileged-only region is refused on privilege" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    try fx.engine.setRegister(.control, status.npriv);
    try fx.store(layout.privileged_only);
    const hit = fx.guard.latch.pending orelse return error.NotRefused;
    try std.testing.expect(hit.kind == .store);
    try std.testing.expect(hit.reason == .privilege);
    try std.testing.expectEqual(layout.privileged_only, hit.address);
    try std.testing.expectEqual(layout.code, hit.pc);
}

test "the same store from handler mode is allowed, whatever CONTROL says" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    try fx.engine.setRegister(.control, status.npriv);
    try fx.engine.setRegister(.xpsr, status.in_handler);
    try fx.store(layout.privileged_only);
    try std.testing.expect(fx.guard.latch.pending == null);
    try std.testing.expectEqual(@as(u64, 0), fx.guard.latch.violations);
    try std.testing.expectEqual(@as(u32, 0x5A5A_5A5A), try fx.engine.readWord(layout.privileged_only));
}

test "the same store from privileged thread mode is allowed" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    try fx.engine.setRegister(.control, 0);
    try fx.store(layout.privileged_only);
    try std.testing.expectEqual(@as(u64, 0), fx.guard.latch.violations);
}

test "a fetch out of an execute-never region is refused on its permissions" {
    var fx: Fixture = undefined;
    try fx.open();
    defer fx.close();
    try fx.engine.write(layout.execute_never, &two_nops);
    _ = try fx.engine.runChunk(layout.execute_never, 2, null);
    const hit = fx.guard.latch.pending orelse return error.NotRefused;
    try std.testing.expect(hit.kind == .fetch);
    try std.testing.expect(hit.reason == .permission);
    try std.testing.expectEqual(layout.execute_never, hit.pc);
}
