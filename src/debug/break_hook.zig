//! Unicorn's code hook on one instruction, feeding `--break-sym`'s break
//! through the debugger's stop machine.
//!
//! src/debug/stop_machine.zig decides when a session stops, and the
//! command layer and the GDB stub drive that same machine. `--break-sym`
//! goes through it too, so the flag and an interactive break count an
//! arrival the same way.
//!
//! The hook still covers only the break's own address, so its cost falls
//! on the blocks that contain the break and not on every instruction the
//! run executes. Stepping needs every instruction and uses
//! src/debug/step_hook.zig instead.
//!
//! The run loop and the report read the caller's `Break` (`reached`,
//! `seen`), so after each arrival the machine's count is copied back to it.
const std = @import("std");
const c = @import("../core/c.zig");
const break_table = @import("break_table.zig");
const breakpoint = @import("breakpoint.zig");
const stop_machine = @import("stop_machine.zig");

pub const Error = error{AttachFailed};

/// One break, the machine that counts it, and the caller's copy to keep
/// current.
pub const Link = struct {
    machine: stop_machine.Machine = .{},
    id: break_table.Id = 0,
    point: *breakpoint.Break,

    /// Hand the machine one arrival at the break. Returns true when this
    /// is the arrival that ends the run.
    pub fn arrive(self: *Link, address: u32, size: u8) bool {
        const event = stop_machine.Event{ .pc = address, .size = size, .sp = 0 };
        const stop = self.machine.onInstruction(event);
        if (self.machine.breaks.get(self.id)) |counted| self.point.* = counted;
        if (stop == null) return false;
        // Arrivals after the wanted one keep counting, as they always did,
        // so a report can say how many there were.
        self.machine.begin();
        return true;
    }
};

/// Put `point` in a fresh machine and set it running.
pub fn link(point: *breakpoint.Break) Link {
    var made = Link{ .point = point };
    made.id = made.machine.breaks.add(point.*) catch unreachable;
    made.machine.begin();
    return made;
}

/// Install the hook. The link has to outlive the engine, which keeps its
/// pointer for every later run, so it is allocated here and left for the
/// process to reclaim; a run attaches at most one break.
pub fn attach(handle: ?*c.uc.uc_engine, point: *breakpoint.Break) Error!void {
    const owned = std.heap.page_allocator.create(Link) catch return Error.AttachFailed;
    owned.* = link(point);
    const at = point.watchedAddress();
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_CODE,
        @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
        owned,
        at,
        at,
    ) != c.uc.UC_ERR_OK) {
        std.heap.page_allocator.destroy(owned);
        return Error.AttachFailed;
    }
}

/// Called before the instruction at the break runs. Stopping here leaves
/// the program counter on the break itself, which is what makes the
/// reported address the function's own entry rather than the one after it.
fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    const owned: *Link = @ptrCast(@alignCast(user orelse return));
    const width: u8 = @intCast(@min(size, 4));
    if (owned.arrive(@truncate(address), width)) _ = c.uc.uc_emu_stop(uc);
}
