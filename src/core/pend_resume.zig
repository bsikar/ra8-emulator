//! Where a thread resumes after the store that pended it.
//!
//! The pend hook stops the stretch from inside the store's own write, and
//! the program counter is left ON that store with the write already
//! made. Resuming there runs the store a second time. For an ordinary word
//! that is harmless; for `ICSR.PENDSVSET` it is a second request to switch.
//!
//! Measured on `threadx_canfd_demo` with `--drain-pends`: PendSV was taken
//! at the store, stacked the store's own address as the return, and the
//! thread it later resumed ran the store again, pended again and was
//! switched straight back out. 3000 PendSV entries came from that one
//! address over 200 ms, and neither thread ever returned from its first
//! `tx_thread_sleep`. On the default path the same double store fed the
//! swallowed pile: the RX thread, which sleeps 50 ticks, looped 129 times
//! in 200 ms where the firmware asks for four.
//!
//! So at the boundary a stop made, before the controller stacks a frame,
//! the program counter is moved past the store. The width comes from the
//! first halfword, the same test src/core/undefined_ops.zig uses.
const undefined_ops = @import("undefined_ops.zig");
const pend_break = @import("pend_break.zig");

/// Step past the store the stretch stopped on, if the core is still on it.
pub fn pastStore(core: anytype, pending: *pend_break.Pend) !void {
    const pc = try core.register(.pc);
    if (pc != pending.ended_at) return;
    const word = try core.readWord(pc & ~@as(u32, 3));
    const half: u16 = @truncate(if (pc & 2 != 0) word >> 16 else word);
    const next = pc + @as(u32, if (undefined_ops.isWide(half)) 4 else 2);
    try core.setRegister(.pc, next);
    pending.steppedPast(next);
}
