//! The modelled time bases: the DWT cycle counter and SysTick.
//!
//! Unicorn stops at instruction boundaries and has no clock of its own, so
//! nothing inside the PPB moves on its own. The firmware does not care that a
//! clock is missing until it waits on one: `ra8_delay_ms` spins on DWT_CYCCNT
//! whenever interrupts are masked (which is the whole of early bring-up, since
//! SystemInit runs `cpsid i`), and a bare-metal delay spins on SysTick's
//! COUNTFLAG. Against a plain-RAM PPB both reads answer the same value forever
//! and the run burns its whole budget in one loop.
//!
//! So the run loop is chunked, and one chunk of execution is charged as one
//! chunk of time: the C emulator on dev charges DWT_CYCCNT
//! `k_dwt_cyccnt_per_chunk` (500000, the same number as its chunk budget) per
//! outer chunk and arms one SysTick period in the same place. This is that
//! cadence, with SysTick counted down properly rather than armed.
const std = @import("std");
const memmap = @import("../core/memmap.zig");

/// Instructions per outer chunk: the C tree's k_run_chunk_insns, which is also
/// the number of cycles it charges per chunk (~1 IPC on the M85).
pub const chunk_instructions: u32 = 500_000;

/// SYST_CSR bits.
pub const csr_enable: u32 = 1 << 0;
pub const csr_tickint: u32 = 1 << 1;
pub const csr_countflag: u32 = 1 << 16;

/// The SysTick counter and its reload are 24-bit.
pub const counter_mask: u32 = 0x00FF_FFFF;

/// ICSR.PENDSTSET: the SysTick exception is pended.
pub const icsr_pendstset: u32 = 1 << 26;

/// DWT_CTRL.CYCCNTENA and DEMCR.TRCENA, the two enables CYCCNT counts behind.
pub const dwt_ctrl_cyccntena: u32 = 1 << 0;
pub const demcr_trcena: u32 = 1 << 24;

/// The time bases, advanced once per chunk by whoever runs the core.
///
/// The counters here are telemetry, not architectural state: the registers the
/// firmware reads are the PPB words themselves, which is why every field below
/// is a count of what this model did rather than a shadow of a register.
pub const Clocks = struct {
    /// Instructions charged per advance. A field rather than a constant so a
    /// test can run a short chunk; the default is the C tree's chunk.
    per_chunk: u32 = chunk_instructions,
    /// Cycles charged to DWT_CYCCNT.
    cycles: u64 = 0,
    /// SysTick periods that elapsed.
    ticks: u64 = 0,
    /// Periods that pended the SysTick exception (TICKINT was set).
    pends: u64 = 0,

    /// Charge `instructions` worth of time to both bases. `core` is anything
    /// that can read and write a PPB word; the engine is one.
    pub fn advance(self: *Clocks, core: anytype, instructions: u32) !void {
        try self.advanceCycleCounter(core, instructions);
        try self.advanceSysTick(core, instructions);
    }

    /// DWT_CYCCNT counts only while DEMCR.TRCENA and DWT_CTRL.CYCCNTENA are
    /// both set (DDI0553 D1.2.1), which is what `ra8_time_init` arms. An app
    /// that never enables it sees the counter stay where the firmware left it,
    /// so this is inert until the firmware opts in. Read-modify-write, so a
    /// firmware `DWT->CYCCNT = 0` is honoured and the count resumes from there.
    fn advanceCycleCounter(self: *Clocks, core: anytype, instructions: u32) !void {
        if (try core.readWord(memmap.scb.demcr) & demcr_trcena == 0) return;
        if (try core.readWord(memmap.dwt.ctrl) & dwt_ctrl_cyccntena == 0) return;
        const current = try core.readWord(memmap.dwt.cyccnt);
        try core.writeWord(memmap.dwt.cyccnt, current +% instructions);
        self.cycles += instructions;
    }

    /// SysTick counts down from SYST_RVR, wraps to the reload, and sets
    /// COUNTFLAG on every wrap; with TICKINT set a wrap also pends the SysTick
    /// exception in ICSR. Taking that exception is the NVIC's job and is not
    /// modelled yet, so the pend bit is left standing for it.
    ///
    /// COUNTFLAG is cleared by a read of SYST_CSR on hardware. A plain-RAM PPB
    /// cannot see reads, so it is cleared at the next chunk boundary instead:
    /// a poll gets one chunk to observe each wrap, and a firmware that never
    /// polls does not accumulate a flag that was never true for a whole period.
    fn advanceSysTick(self: *Clocks, core: anytype, instructions: u32) !void {
        const csr = try core.readWord(memmap.syst.csr);
        var next = csr & ~csr_countflag;
        defer_write: {
            if (csr & csr_enable == 0) break :defer_write; // disabled: the counter holds.
            const reload = try core.readWord(memmap.syst.rvr) & counter_mask;
            if (reload == 0) break :defer_write; // a zero reload never wraps.
            const current = try core.readWord(memmap.syst.cvr) & counter_mask;
            const wrapped = wrap(current, reload, instructions);
            try core.writeWord(memmap.syst.cvr, wrapped.value);
            if (wrapped.periods == 0) break :defer_write;
            self.ticks += wrapped.periods;
            next |= csr_countflag;
            if (csr & csr_tickint != 0) {
                const icsr = try core.readWord(memmap.scb.icsr);
                try core.writeWord(memmap.scb.icsr, icsr | icsr_pendstset);
                self.pends += 1;
            }
        }
        if (next != csr) try core.writeWord(memmap.syst.csr, next);
    }
};

pub const Wrapped = struct { value: u32, periods: u64 };

/// Where a counter at `current` lands after `count` ticks, and how many times
/// it passed zero on the way. The counter spends one tick at zero before it
/// reloads, so a period is reload + 1 ticks long.
pub fn wrap(current: u32, reload: u32, count: u32) Wrapped {
    if (count <= current) return .{ .value = current - count, .periods = 0 };
    const period: u64 = @as(u64, reload) + 1;
    const past: u64 = @as(u64, count) - current - 1;
    return .{
        .value = reload - @as(u32, @intCast(past % period)),
        .periods = 1 + past / period,
    };
}
