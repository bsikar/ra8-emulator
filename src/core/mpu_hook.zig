//! Unicorn's memory-write hook over the MPU register window.
//!
//! src/periph/mpu.zig knows what RNR, RBAR and RLAR mean and nothing about
//! Unicorn. This file is the other half: it catches each store the firmware
//! makes into the window, hands it to the block, and when RNR moves it puts
//! the newly selected pairs back in front of the firmware. Keeping the two
//! apart is what lets the banking be tested without a live engine.
//!
//! A WRITE HOOK RATHER THAN A BUS BLOCK, and the reason is the map. The
//! peripheral registry answers on its own MMIO window, but the MPU registers
//! sit inside the PPB, which is mapped as ordinary RAM, and a hole cannot be
//! cut for them: Unicorn maps on 4 KiB boundaries and the page holding the
//! MPU also holds SysTick, the NVIC and most of the SCB. A ranged write hook
//! needs no alignment, so it is what fits. The store still lands in the RAM
//! underneath, which is what keeps every register in the window readable for
//! free; only the banked pairs are put back.
const c = @import("c.zig");
const memmap = @import("memmap.zig");
const mpu = @import("../periph/mpu.zig");

pub const Error = error{AttachFailed};

/// The window the hook watches: TYPE through MAIR1, inclusive.
pub const window = struct {
    pub const first: u64 = memmap.mpu.type_;
    pub const last: u64 = memmap.mpu.mair1 + 3;
};

pub fn attach(handle: ?*c.uc.uc_engine, unit: *mpu.Mpu) Error!void {
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
    const unit: *mpu.Mpu = @ptrCast(@alignCast(user.?));
    const moved = unit.observe(@truncate(address), @bitCast(@as(i32, @truncate(value))));
    if (!moved) return;
    const handle = uc orelse return;
    rebank(handle, unit);
}

/// Put the four pairs RNR now selects back into the words the firmware
/// reads. uc_mem_write is an API call rather than a guest access, so it
/// does not come back through this hook.
fn rebank(handle: ?*c.uc.uc_engine, unit: *const mpu.Mpu) void {
    const pairs = [_][2]u32{
        .{ memmap.mpu.rbar, memmap.mpu.rlar },
        .{ memmap.mpu.rbar_a1, memmap.mpu.rlar_a1 },
        .{ memmap.mpu.rbar_a2, memmap.mpu.rlar_a2 },
        .{ memmap.mpu.rbar_a3, memmap.mpu.rlar_a3 },
    };
    for (pairs, 0..) |where, offset| {
        const words = unit.pairFor(@intCast(offset));
        writeWord(handle, where[0], words[0]);
        writeWord(handle, where[1], words[1]);
    }
}

fn writeWord(handle: ?*c.uc.uc_engine, address: u32, value: u32) void {
    var word = value;
    _ = c.uc.uc_mem_write(handle, address, &word, @sizeOf(u32));
}
