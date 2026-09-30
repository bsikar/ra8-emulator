//! Unicorn's memory-write hook, over the whole address space, armed only
//! while a closure probe is in flight.
//!
//! src/core/idle.zig knows what a closed loop is and nothing about Unicorn.
//! This file is the other half: it catches every store a probe makes and
//! decides whether the model can show it changed nothing.
//!
//! A STORE THAT WRITES BACK WHAT IS ALREADY THERE changes nothing, and that
//! is not a corner case here: `__tx_ts_wait` stores `_tx_thread_execute_ptr`
//! over `_tx_thread_current_ptr` on every pass, and while the system is idle
//! both are zero. Reading the word before the store is the only way to tell
//! that from a store that moves a counter, so the hook reads it.
//!
//! A STORE ANYWHERE BUT ORDINARY RAM DISTURBS THE SEAM whatever value it
//! carries. A peripheral register can act on a write that leaves its own
//! read-back where it was, and this tree is full of them: CRCCR0.DORCLR
//! clears a remainder, RCR2.RESET restarts a counter, SPDR clocks a frame
//! out. The value written proves nothing there, so the probe gives up
//! instead.
//!
//! THE WHOLE ADDRESS SPACE, not a window, because a probe does not know
//! where the loop it is watching will store. The cost is a compare and a
//! return per store while the seam is disarmed, which is everywhere outside
//! a probe; measured on this corpus it does not show above the noise.
const c = @import("c.zig");
const idle = @import("idle.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, seam: *idle.Seam) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        seam,
        0,
        0xFFFF_FFFF,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Called as the store happens, which is before it lands: the word read
/// here is still the one the store is about to replace.
fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    const seam: *idle.Seam = @ptrCast(@alignCast(user orelse return));
    if (!seam.armed) return;
    const handle = uc orelse return;
    const width: u32 = @intCast(size);
    if (!idle.plainMemory(address, width) or width > 8) return seam.disturb();
    var held: [8]u8 = @splat(0);
    if (c.uc.uc_mem_read(handle, address, &held, width) != c.uc.UC_ERR_OK) {
        return seam.disturb();
    }
    const carried: u64 = @bitCast(value);
    var index: u32 = 0;
    while (index < width) : (index += 1) {
        const byte: u8 = @truncate(carried >> @intCast(index * 8));
        if (held[index] != byte) return seam.disturb();
    }
}
