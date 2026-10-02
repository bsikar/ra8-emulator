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
const c = @import("../core/c.zig");
const call_decode = @import("call_decode.zig");
const stop_machine = @import("stop_machine.zig");
const breakpoint = @import("breakpoint.zig");

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

    /// Clear the previous verdict before a run is started.
    pub fn arm(self: *Driver) void {
        self.last = null;
    }
};

/// Install the hooks. The memory hook is only installed when `watch_memory`
/// is set, because a hook on every access costs every access.
pub fn attach(handle: ?*c.uc.uc_engine, driver: *Driver, watch_memory: bool) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(handle, &hook, c.uc.UC_HOOK_CODE, @constCast(@as(*const anyopaque, @ptrCast(&onCode))), driver, 1, 0) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
    if (!watch_memory) return;
    const kinds = c.uc.UC_HOOK_MEM_READ | c.uc.UC_HOOK_MEM_WRITE;
    if (c.uc.uc_hook_add(handle, &hook, kinds, @constCast(@as(*const anyopaque, @ptrCast(&onMemory))), driver, 1, 0) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    const driver: *Driver = @ptrCast(@alignCast(user orelse return));
    const handle = uc orelse return;
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
    if (driver.machine.onInstruction(event)) |stop| {
        driver.last = stop;
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
    _ = value;
    const driver: *Driver = @ptrCast(@alignCast(user orelse return));
    const access: @import("watch_table.zig").Access = if (kind == c.uc.UC_MEM_WRITE) .write else .read;
    driver.machine.onAccess(@truncate(address), @intCast(size), access);
}
