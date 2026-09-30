//! Unicorn's memory-write hook over the SAU register window.
//!
//! src/periph/sau.zig knows what RNR, RBAR and RLAR mean and nothing about
//! Unicorn. This file is the other half: it catches each store the firmware
//! makes into the window, hands it to the block, and when RNR moves it puts
//! the newly selected pair back in front of the firmware. Keeping the two
//! apart is what lets the banking be tested without a live engine.
//!
//! A WRITE HOOK RATHER THAN A BUS BLOCK, for the same reason the MPU window
//! next door uses one: the peripheral registry answers on its own MMIO
//! window, but these registers sit inside the PPB, which is mapped as
//! ordinary RAM, and a hole cannot be cut for them. Unicorn maps on 4 KiB
//! boundaries and the page holding the SAU also holds the MPU and most of
//! the SCB. A ranged write hook needs no alignment, so it is what fits. The
//! store still lands in the RAM underneath, which keeps every register in
//! the window readable for free; only the banked pair is put back.
//!
//! NO GUARD, unlike src/core/mpu_hook.zig: that hook carries a guard because
//! a store to MPU_CTRL arms or disarms real enforcement traps. This model
//! does not enforce attribution (src/periph/sau.zig says why), so the block
//! itself is all the hook needs to carry.
const c = @import("c.zig");
const memmap = @import("memmap.zig");
const sau = @import("../periph/sau.zig");

pub const Error = error{AttachFailed};

/// The window the hook watches: CTRL through RLAR, inclusive.
pub const window = struct {
    pub const first: u64 = memmap.sau.ctrl;
    pub const last: u64 = memmap.sau.rlar + 3;
};

pub fn attach(handle: ?*c.uc.uc_engine, unit: *sau.Sau) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        unit,
        window.first,
        window.last,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Unicorn reports the store before it lands, which does not matter here:
/// nothing read back in this callback is a word the store is about to
/// change, and the words it does write are the ones the store is not.
fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    // Every register in the window is a word, and every driver writes them
    // as words. A narrower store is left to the RAM underneath rather than
    // filed as a whole register.
    if (size != 4) return;
    const unit: *sau.Sau = @ptrCast(@alignCast(user.?));
    const handle = uc orelse return;
    const word: u32 = @bitCast(@as(i32, @truncate(value)));
    switch (unit.observe(@truncate(address), word)) {
        .none => {},
        .rebank => rebank(handle, unit),
    }
}

/// Put the newly selected region's pair back into the RAM under the window,
/// so the firmware's next read of RBAR/RLAR gives the region RNR names
/// rather than whatever the last programmed one left behind.
fn rebank(handle: ?*c.uc.uc_engine, unit: *sau.Sau) void {
    const pair = unit.bankedPair();
    put(handle, memmap.sau.rbar, pair.rbar);
    put(handle, memmap.sau.rlar, pair.rlar);
}

fn put(handle: ?*c.uc.uc_engine, address: u32, word: u32) void {
    var buffer = word;
    _ = c.uc.uc_mem_write(handle, address, &buffer, @sizeOf(u32));
}
