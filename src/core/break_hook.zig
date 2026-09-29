//! Unicorn's code hook, narrowed to one instruction: the break.
//!
//! src/core/breakpoint.zig knows which arrival ends a run and nothing about
//! Unicorn. This file is the other half: it asks to be called on the break's
//! own address and nowhere else, counts the arrival, and stops the emulator
//! when the count is the one that was asked for.
//!
//! The range is a single instruction, so the cost of the hook falls on the
//! blocks that contain it rather than on every block the run translates.
const c = @import("c.zig");
const breakpoint = @import("breakpoint.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, point: *breakpoint.Break) Error!void {
    var hook: c.uc.uc_hook = 0;
    const at = point.watchedAddress();
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_CODE,
        @constCast(@as(*const anyopaque, @ptrCast(&onCode))),
        point,
        at,
        at,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Called before the instruction at the break runs. Stopping here leaves
/// the program counter on the break itself, which is what makes the
/// reported address the function's own entry rather than the one after it.
fn onCode(uc: ?*c.uc.uc_engine, address: u64, size: u32, user: ?*anyopaque) callconv(.C) void {
    _ = address;
    _ = size;
    const point: *breakpoint.Break = @ptrCast(@alignCast(user orelse return));
    if (point.count()) _ = c.uc.uc_emu_stop(uc);
}
