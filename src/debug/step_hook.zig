//! Unicorn's hooks, feeding the stop machine from a live run.
//!
//! src/debug/stop_machine.zig decides when a session stops and knows
//! nothing about Unicorn. This file is the other half: a code hook over
//! every instruction hands the machine an event, and a memory hook hands it
//! the accesses the watches care about. When the machine says stop, the
//! emulator is stopped before the instruction runs, so the program counter
//! is left on the instruction that has not executed yet.
//!
//! When the core lane's Zig CPU exposes single-step and halt, its loop
//! feeds the same machine and this file goes with Unicorn.
const std = @import("std");
const c = @import("../core/c.zig");
const call_decode = @import("call_decode.zig");
const stop_machine = @import("stop_machine.zig");
const breakpoint = @import("breakpoint.zig");
const fpb = @import("fpb.zig");
const dwt = @import("dwt.zig");
const itm = @import("itm.zig");
const dcb = @import("dcb.zig");

pub const Error = error{AttachFailed};

/// The machine a run is driven by, and how the last run ended.
pub const Driver = struct {
    machine: *stop_machine.Machine,
    /// Why the last run stopped, or null when it spent its budget.
    last: ?stop_machine.Stop = null,
    /// Set as reached when the machine stops, so a run loop driving the
    /// core ends at the stop instead of starting its next stretch. Null on
    /// a bare run, where stopping the engine is enough.
    latch: ?*breakpoint.Break = null,
    /// The firmware wrote the FPB since its registers were last put back
    /// into memory. The PPB is plain memory, so the word just stored is
    /// what a read would see until the register file is written over it.
    unit_dirty: bool = false,

    /// Clear the previous verdict before a run is started.
    pub fn arm(self: *Driver) void {
        self.last = null;
    }

    /// A store the firmware made, handed to the FPB when it lands there.
    fn stored(self: *Driver, address: u32, value: u32, width: u8) void {
        if (inside(address, itm.base, itm.limits.span)) {
            _ = self.machine.itm.write(address - itm.base, value, width);
        } else if (inside(address, fpb.base, fpb.limits.span)) {
            if (self.machine.fpb.write(address - fpb.base, value)) self.unit_dirty = true;
        } else if (inside(address, dwt.base, dwt.limits.end)) {
            _ = self.machine.dwt.write(address - dwt.base, value);
        } else if (address == dcb.dfsr_address) {
            self.machine.dcb.clearStatus(value);
        } else if (inside(address, dcb.base, dcb.span)) {
            _ = self.machine.dcb.write(address - dcb.base, value);
            if (self.machine.dcb.takeHalt()) self.machine.requestHalt();
        }
    }

    /// A load the firmware made, which may clear a DWT MATCHED flag.
    fn loaded(self: *Driver, address: u32) void {
        if (inside(address, dwt.base, dwt.limits.end)) self.machine.dwt.loaded(address - dwt.base);
    }
};

fn inside(address: u32, from: u32, span: u32) bool {
    return address >= from and address < from + span;
}

/// Put the FPB's and the DWT comparators' registers in memory the way a
/// read should see them.
fn syncUnits(handle: *c.uc.uc_engine, machine: *stop_machine.Machine) void {
    var offset: u32 = 0;
    while (offset < fpb.limits.span) : (offset += 4) {
        if (machine.fpb.read(offset)) |word| put(handle, fpb.base + offset, word);
    }
    offset = dwt.offsets.comp0;
    while (offset < dwt.limits.end) : (offset += 4) {
        if (machine.dwt.peek(offset)) |word| put(handle, dwt.base + offset, word);
    }
    machine.dwt.changed = false;
    var port: u32 = 0;
    while (port < itm.limits.ports) : (port += 1) put(handle, itm.base + port * 4, itm.fifo_ready);
    for ([_]u32{ itm.offsets.ter, itm.offsets.tpr, itm.offsets.tcr }) |register| {
        if (machine.itm.peek(register)) |word| put(handle, itm.base + register, word);
    }
    machine.itm.changed = false;
    offset = 0;
    while (offset < dcb.span) : (offset += 4) {
        if (machine.dcb.peek(offset)) |word| put(handle, dcb.base + offset, word);
    }
    put(handle, dcb.dfsr_address, machine.dcb.dfsr);
    machine.dcb.changed = false;
}

/// The DFSR bits a halt records.
fn dfsrFor(stop: stop_machine.Stop) u32 {
    return switch (stop) {
        .breakpoint, .unit_break => dcb.dfsr_bits.bkpt,
        .watchpoint, .unit_watch => dcb.dfsr_bits.dwttrap,
        .stepped, .halt_requested => dcb.dfsr_bits.halted,
    };
}

/// A unit event with halting debug off: if DEMCR.MON_EN is set, latch DFSR
/// and set DEMCR.MON_PEND for the interrupt controller to take
/// DebugMonitor at its next boundary. The instruction it matched still
/// runs; with MON_EN clear the event is dropped.
fn pendMonitor(handle: *c.uc.uc_engine, machine: *stop_machine.Machine, cause: stop_machine.Monitor) void {
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    if (c.uc.uc_mem_read(handle, dcb.demcr_address, &bytes, bytes.len) != c.uc.UC_ERR_OK) return;
    const demcr = std.mem.readInt(u32, &bytes, .little);
    if (demcr & dcb.demcr_bits.mon_en == 0) return;
    put(handle, dcb.demcr_address, demcr | dcb.demcr_bits.mon_pend);
    machine.dcb.latch(if (cause == .breakpoint) dcb.dfsr_bits.bkpt else dcb.dfsr_bits.dwttrap);
    put(handle, dcb.dfsr_address, machine.dcb.dfsr);
}

fn unitsChanged(machine: *const stop_machine.Machine) bool {
    return machine.dwt.changed or machine.itm.changed or machine.dcb.changed;
}

fn put(handle: *c.uc.uc_engine, address: u32, word: u32) void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, word, .little);
    _ = c.uc.uc_mem_write(handle, address, &bytes, bytes.len);
}

/// Install the hooks. The memory hook is only installed when `watch_memory`
/// is set, because a hook on every access costs every access.
pub fn attach(handle: ?*c.uc.uc_engine, driver: *Driver, watch_memory: bool) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(handle, &hook, c.uc.UC_HOOK_CODE, @constCast(@as(*const anyopaque, @ptrCast(&onCode))), driver, 1, 0) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
    if (!watch_memory) return;
    if (driver.machine.halting) driver.machine.dcb.attachDebugger();
    if (handle) |live| syncUnits(live, driver.machine);
    const kinds = c.uc.UC_HOOK_MEM_READ | c.uc.UC_HOOK_MEM_WRITE;
    if (c.uc.uc_hook_add(handle, &hook, kinds, @constCast(@as(*const anyopaque, @ptrCast(&onMemory))), driver, 1, 0) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    const driver: *Driver = @ptrCast(@alignCast(user orelse return));
    const handle = uc orelse return;
    if (driver.unit_dirty or unitsChanged(driver.machine)) {
        syncUnits(handle, driver.machine);
        driver.unit_dirty = false;
    }
    var sp: u32 = 0;
    if (c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_SP, &sp) != c.uc.UC_ERR_OK) sp = 0;
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    const width: usize = @min(size, bytes.len);
    if (c.uc.uc_mem_read(handle, address, &bytes, width) != c.uc.UC_ERR_OK) bytes = .{ 0, 0, 0, 0 };
    const event = stop_machine.Event{
        .pc = @truncate(address),
        .size = @intCast(width),
        .sp = sp,
        .call = call_decode.isCall(bytes[0..width]),
    };
    const stop = driver.machine.onInstruction(event);
    if (driver.machine.takeMonitor()) |cause| pendMonitor(handle, driver.machine, cause);
    if (stop) |why| {
        driver.machine.dcb.latch(dfsrFor(why));
        driver.last = why;
        if (driver.latch) |latch| latch.reached = true;
        _ = c.uc.uc_emu_stop(handle);
    }
}

fn onMemory(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = uc;
    const driver: *Driver = @ptrCast(@alignCast(user orelse return));
    const access: @import("watch_table.zig").Access = if (kind == c.uc.UC_MEM_WRITE) .write else .read;
    if (access == .write) {
        driver.stored(@truncate(address), @truncate(@as(u64, @bitCast(value))), @intCast(size));
    } else {
        driver.loaded(@truncate(address));
    }
    driver.machine.onAccess(@truncate(address), @intCast(size), access);
}
