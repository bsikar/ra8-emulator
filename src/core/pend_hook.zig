//! Unicorn's memory-write hook, narrowed to the one word that pends an
//! exception by hand.
//!
//! src/core/pend_break.zig knows what a pend means and nothing about
//! Unicorn. This file is the other half: it asks to be called for stores
//! into `ICSR` and nowhere else, decides whether the stored value
//! actually raises a pend, and stops the stretch if it does.
//!
//! Only `PENDSVSET` counts. The SysTick pend is the model's own, written
//! through the engine at a boundary where no hook runs and where the
//! controller is about to look anyway; a firmware store of `PENDSTCLR`
//! or of an unrelated field in the same word raises nothing and must not
//! cut the stretch.
const c = @import("c.zig");
const memmap = @import("memmap.zig");
const nvic = @import("../periph/nvic.zig");
const pend_break = @import("pend_break.zig");

pub const Error = error{AttachFailed};

pub fn attach(handle: ?*c.uc.uc_engine, pending: *pend_break.Pend) Error!void {
    var hook: c.uc.uc_hook = 0;
    if (c.uc.uc_hook_add(
        handle,
        &hook,
        c.uc.UC_HOOK_MEM_WRITE,
        @constCast(@as(*const anyopaque, @ptrCast(&onWrite))),
        pending,
        memmap.scb.icsr,
        memmap.scb.icsr + 3,
    ) != c.uc.UC_ERR_OK) {
        return Error.AttachFailed;
    }
}

/// Called as the store happens. Stopping here rather than at the next
/// boundary is the whole point: the instruction after this one is where
/// the architecture would already be in the handler.
///
/// ONLY A TRANSITION COUNTS. The bit standing in the register already
/// means the exception is pending and the controller has not been able
/// to take it yet, so a store that merely carries it along raises
/// nothing and must not cut the stretch. Two writers do exactly that:
/// the model's own SysTick pend reads ICSR, ors PENDSTSET in and writes
/// the word back, PENDSVSET included, and ThreadX writes PENDSVSET on
/// every suspend whether or not one is outstanding. Latching on the
/// value alone cut every boundary of the run: 3.5 million of them over
/// four modelled seconds, against 72 real pends.
fn onWrite(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) void {
    _ = kind;
    _ = address;
    _ = size;
    const pending: *pend_break.Pend = @ptrCast(@alignCast(user orelse return));
    const handle = uc orelse return;
    const written: u32 = @truncate(@as(u64, @bitCast(value)));
    if (written & nvic.icsr_pendsvset == 0) return;
    var standing: u32 = 0;
    if (c.uc.uc_mem_read(handle, memmap.scb.icsr, &standing, @sizeOf(u32)) != c.uc.UC_ERR_OK) return;
    if (standing & nvic.icsr_pendsvset != 0) return;
    pending.record();
    _ = c.uc.uc_emu_stop(handle);
}
