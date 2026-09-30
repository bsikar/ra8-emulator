//! Unicorn's memory-write hook over SYST_CSR and SYST_RVR.
//!
//! src/periph/clocks.zig knows what a SysTick period is and nothing about
//! Unicorn. This file is the other half: it catches the store that arms the
//! counter and ends the stretch of execution in flight, so the boundary after
//! it is cut from the period the firmware just asked for.
//!
//! WHY A BOUNDARY HAS TO END HERE. The engine sizes each stretch from the
//! period armed when the stretch begins, and at reset nothing is armed, so
//! the first stretch is a whole boundary wide. `ra8_time_init` arms SysTick
//! inside that stretch, at a kilohertz, and on this corpus a kilohertz is a
//! few thousand instructions: the one stretch that arms the counter therefore
//! covers several periods, and COUNTFLAG and the pend bit are single latches,
//! so all but the first of them raise nothing. `blink` loses five that way
//! and never gets them back, because `ra8_delay_ms` loops on the `s_tick_ms`
//! those periods would have incremented. Ending the stretch at the store is
//! what keeps the boundary from being wider than the period it carries.
//!
//! A WRITE HOOK RATHER THAN A BUS BLOCK, for the same reason the SAU and MPU
//! windows next door use one: SysTick sits inside the PPB, which is mapped as
//! ordinary RAM on 4 KiB boundaries, and a hole cannot be cut for it. The
//! store still lands in the RAM underneath, which is what keeps both
//! registers readable for free.
const c = @import("c.zig");
const memmap = @import("memmap.zig");
const clocks = @import("../periph/clocks.zig");

pub const Error = error{AttachFailed};

/// The window the hook watches: SYST_CSR and SYST_RVR. SYST_CVR is
/// deliberately outside it. The counter itself is written by the model at
/// every boundary and by the firmware to restart a period, and neither
/// changes how wide the period is.
pub const window = struct {
    pub const first: u64 = memmap.syst.csr;
    pub const last: u64 = memmap.syst.rvr + 3;
};

pub fn attach(handle: ?*c.uc.uc_engine, clock: *clocks.Clocks) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        clock,
        window.first,
        window.last,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Unicorn reports the store before it lands, so the two words read back
/// here are the state the firmware is changing away from, which is exactly
/// what the decision needs.
fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    // Both registers are words and every driver writes them as words. A
    // narrower store is left to the RAM underneath rather than read as a
    // whole register.
    if (size != 4) return;
    const clock: *clocks.Clocks = @ptrCast(@alignCast(user.?));
    const handle = uc orelse return;
    const word: u32 = @bitCast(@as(i32, @truncate(value)));
    const offset: u32 = @truncate(address);
    switch (clocks.observe(offset, word, read(handle, memmap.syst.csr), read(handle, memmap.syst.rvr))) {
        .none => {},
        .rearm => {
            // Put the store where it was going before stopping, so the
            // register holds what the firmware asked for whether or not the
            // stop beats the write to it.
            put(handle, offset, word);
            clock.armed();
            _ = c.uc.uc_emu_stop(handle);
        },
    }
}

fn read(handle: ?*c.uc.uc_engine, address: u32) u32 {
    var buffer: u32 = 0;
    _ = c.uc.uc_mem_read(handle, address, &buffer, @sizeOf(u32));
    return buffer;
}

fn put(handle: ?*c.uc.uc_engine, address: u32, word: u32) void {
    var buffer = word;
    _ = c.uc.uc_mem_write(handle, address, &buffer, @sizeOf(u32));
}
