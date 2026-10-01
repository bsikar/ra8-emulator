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
const pend_clear = @import("pend_clear.zig");

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
/// ONLY A TRANSITION RAISES A PEND. The bit standing in the register
/// already means the exception is pending and the controller has not been
/// able to take it yet, so a store that merely carries it along raises
/// nothing. Two writers do exactly that: the model's own SysTick pend
/// reads ICSR, ors PENDSTSET in and writes the word back, PENDSVSET
/// included, and ThreadX writes PENDSVSET on every suspend whether or not
/// one is outstanding. Latching a PEND on the value alone cut every
/// boundary of the run: 3.5 million of them over four modelled seconds,
/// against 72 real pends.
///
/// A store that raises nothing can still END THE STRETCH, and must when
/// it comes from Thread mode, because the thread is then running on top
/// of a switch it already asked for. That is bounded by how often the
/// firmware calls its scheduler, not by how often anything touches ICSR:
/// 151 a modelled second on threadx_blink against the 3.5 million above.
/// A store from inside a handler is left alone, since PendSV cannot
/// preempt itself and the look could never take it.
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
    var standing: u32 = 0;
    if (c.uc.uc_mem_read(handle, memmap.scb.icsr, &standing, @sizeOf(u32)) != c.uc.UC_ERR_OK) return;
    if (written & nvic.icsr_pendsvset == 0) {
        // A store that does not carry PENDSVSET raises nothing, but it can
        // still TAKE A STANDING PEND DOWN, because against a plain-RAM PPB a
        // word store is just a word store and the write-one-to-set lane is
        // not honoured. Counted rather than corrected: this hook's job is to
        // say what happens, and src/core/pend_clear.zig says why the count
        // is the reading that settles where the missing pends went.
        if (standing & nvic.icsr_pendsvset != 0) pending.cleared.record(
            programCounter(handle),
            executing(handle),
            written & nvic.icsr_pendsvclr != 0,
        );
        return;
    }
    if (standing & nvic.icsr_pendsvset != 0) {
        pending.alreadyPending(executing(handle));
        pending.swallowedAt(programCounter(handle));
        // A Thread-mode store asked again for a switch that is still owed,
        // and the thread must not be allowed to carry on past it. Nothing
        // is raised here: the bit was already up, and the stop only buys
        // the controller another look at it.
        if (pending.again) {
            pending.endedAt(programCounter(handle));
            _ = c.uc.uc_emu_stop(handle);
        }
        return;
    }
    pending.record();
    pending.endedAt(programCounter(handle));
    _ = c.uc.uc_emu_stop(handle);
}

/// The address of the storing instruction. Stopping here leaves the
/// program counter ON it rather than past it, so this is also the address
/// the next stretch will open on if nothing moves it along.
fn programCounter(handle: *c.uc.uc_engine) u32 {
    var pc: u32 = 0;
    if (c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_PC, &pc) != c.uc.UC_ERR_OK) return 0;
    return pc;
}

/// The exception executing at the store, from IPSR. Zero is Thread mode,
/// and an unreadable register reads as Thread mode too: this only labels a
/// counter and must never be the reason a pend is handled differently.
fn executing(handle: *c.uc.uc_engine) u16 {
    var ipsr: u32 = 0;
    if (c.uc.uc_reg_read(handle, c.uc.UC_ARM_REG_IPSR, &ipsr) != c.uc.UC_ERR_OK) return 0;
    return @truncate(ipsr & nvic.ipsr_mask);
}
