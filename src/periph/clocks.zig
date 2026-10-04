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
const cadence = @import("../core/cadence.zig");
const memmap = @import("../core/memmap.zig");

/// The machine's virtual time and its event queue (RA8EMU-179).
pub const timebase = @import("time/timebase.zig");
pub const event_queue = @import("time/event_queue.zig");
/// When each core's SysTick next wraps (RA8EMU-515).
pub const systick_due = @import("time/systick_due.zig");

/// The machine's clock and what is scheduled on it, as the board holds them.
pub const Time = struct {
    base: timebase.TimeBase = .{},
    queue: event_queue.EventQueue = .{},
};

/// The SDRAM controller and the SDCLK output control: sdramc.zig.
pub const sdram = @import("sdramc.zig");

/// Instructions per outer chunk, and the cycles charged for one (~1 IPC on
/// the M85). The width itself is the run's cadence (src/core/cadence.zig):
/// dev's 500000 was one number for both, and splitting them is what let the
/// boundary get fine enough for a bounded poll loop to see a counter move.
pub const chunk_instructions: u32 = cadence.instructions;

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

/// The words one SysTick timer lives at, and the ICSR its wrap pends into.
/// The default is the timer the normal window names (memmap.syst); a core's
/// Non-secure timer is the same logic run against `non_secure` (RA8EMU-154).
pub const Words = struct {
    csr: u32 = memmap.syst.csr,
    rvr: u32 = memmap.syst.rvr,
    cvr: u32 = memmap.syst.cvr,
    icsr: u32 = memmap.scb.icsr,

    /// The Non-secure timer at the SCS alias, 0xE002_E010 (DDI0553 B6.2).
    /// Its pend word is left to the caller that wires it.
    pub const non_secure = Words{
        .csr = memmap.syst.csr + alias_offset,
        .rvr = memmap.syst.rvr + alias_offset,
        .cvr = memmap.syst.cvr + alias_offset,
    };
};

/// How far the SCS Non-secure alias sits above the normal window.
const alias_offset: u32 = 0x0002_0000;

/// The time bases, advanced once per chunk by whoever runs the core.
///
/// The counters here are telemetry, not architectural state: the registers the
/// firmware reads are the PPB words themselves, which is why every field below
/// is a count of what this model did rather than a shadow of a register.
pub const Clocks = struct {
    /// Instructions charged per advance. A field rather than a constant so a
    /// test can run a short chunk; the default is the C tree's chunk.
    per_chunk: u32 = chunk_instructions,
    /// Which SysTick timer this base counts down.
    words: Words = .{},
    /// Modelled cycles this run covered, one per instruction. Unconditional,
    /// because time passes whether or not the firmware is watching it: this
    /// is the run's own account of how far it got, and it is the only field
    /// here that every image has.
    elapsed: u64 = 0,
    /// Of those, the ones handed to DWT_CYCCNT. The register only counts once
    /// the firmware arms it, so this stays zero for an image that never does,
    /// and the gap between it and `elapsed` is exactly the time that passed
    /// while nothing was watching.
    cycles: u64 = 0,
    /// SysTick periods that elapsed.
    ticks: u64 = 0,
    /// Periods that pended the SysTick exception (TICKINT was set).
    pends: u64 = 0,
    /// Periods a single boundary swallowed: wraps that happened but raised
    /// nothing the firmware could count, because COUNTFLAG and the pend bit
    /// are single latches and the handler cannot run mid-stretch. Time the
    /// firmware is owed and will never be paid.
    collapsed: u64 = 0,
    /// Boundaries cut short because the firmware armed or re-armed SysTick
    /// inside them. Each one is a stretch of execution whose time is not
    /// charged, which is the price of not swallowing the periods it covered.
    rearms: u64 = 0,
    /// Set by src/core/systick_hook.zig when one of those stores lands, and
    /// taken by the run loop at the boundary it caused.
    restart: bool = false,

    /// The hook saw a store that re-sized the period. Counted and latched;
    /// the run loop is what acts on it.
    pub fn armed(self: *Clocks) void {
        self.rearms += 1;
        self.restart = true;
    }

    /// Take the latch, so one store ends one boundary.
    pub fn took(self: *Clocks) bool {
        const hit = self.restart;
        self.restart = false;
        return hit;
    }

    /// How many instructions apart the armed SysTick periods are, or zero
    /// when nothing is armed to ask for a boundary at all.
    ///
    /// The run loop reads this to keep a boundary from being wider than the
    /// period it is meant to deliver. A wrap sets COUNTFLAG and pends the
    /// exception, and both are single bits: several wraps inside one stretch
    /// of execution collapse into one. On the part each period raises its
    /// own, so a firmware counting them (`s_tick_ms` in ra8_time.c, which
    /// `ra8_delay_ms` then loops on) advances once where the part advances it
    /// many times, and every delay built on it runs long by that ratio.
    ///
    /// The period is reload + 1 ticks and a tick is charged per instruction,
    /// so the two are the same number. A disabled counter or a zero reload
    /// never wraps and asks for nothing.
    pub fn period(self: *const Clocks, core: anytype) u32 {
        const csr = core.readWord(self.words.csr) catch return 0;
        if (csr & csr_enable == 0) return 0;
        const reload = (core.readWord(self.words.rvr) catch return 0) & counter_mask;
        if (reload == 0) return 0;
        return reload + 1;
    }

    /// Charge `instructions` worth of time. `core` is anything that can read
    /// and write a PPB word; the engine is one.
    ///
    /// The run's own count moves first and always. The two bases below are
    /// the firmware's, and each has its own opt-in: DWT_CYCCNT counts only
    /// once the firmware arms it, and SysTick only once it is enabled with a
    /// reload. An image that arms neither still spends time here, and saying
    /// so is the difference between a run that did nothing and a run whose
    /// firmware asked for no clock.
    pub fn advance(self: *Clocks, core: anytype, instructions: u32) !void {
        self.elapsed += instructions;
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
    /// exception in ICSR. Taking that exception is the NVIC's job, so the pend
    /// bit is left standing for it.
    ///
    /// Both of those are single bits, and the handler cannot run part way
    /// through a stretch, so a stretch covering several periods delivers one.
    /// `period()` below is what normally keeps a boundary from being wider
    /// than the period it carries, but it stops following the period at
    /// `cadence.floor`: under that the collapse is deliberate, and every
    /// period past the first is one the firmware is never told about. A
    /// firmware counting them (`s_tick_ms` in ra8_time.c, which `ra8_delay_ms`
    /// then loops on) advances once where the part advances it many times, so
    /// every delay built on it runs long by that ratio. Deliberate is not the
    /// same as harmless, so the ones that go missing are counted.
    ///
    /// COUNTFLAG is cleared by a read of SYST_CSR on hardware. A plain-RAM PPB
    /// cannot see reads, so it is cleared at the next chunk boundary instead:
    /// a poll gets one chunk to observe each wrap, and a firmware that never
    /// polls does not accumulate a flag that was never true for a whole period.
    pub fn advanceSysTick(self: *Clocks, core: anytype, instructions: u32) !void {
        const csr = try core.readWord(self.words.csr);
        var next = csr & ~csr_countflag;
        defer_write: {
            if (csr & csr_enable == 0) break :defer_write; // disabled: the counter holds.
            const reload = try core.readWord(self.words.rvr) & counter_mask;
            if (reload == 0) break :defer_write; // a zero reload never wraps.
            const current = try core.readWord(self.words.cvr) & counter_mask;
            const wrapped = wrap(current, reload, instructions);
            try core.writeWord(self.words.cvr, wrapped.value);
            if (wrapped.periods == 0) break :defer_write;
            self.ticks += wrapped.periods;
            self.collapsed += wrapped.periods - 1;
            next |= csr_countflag;
            if (csr & csr_tickint != 0) {
                const icsr = try core.readWord(self.words.icsr);
                try core.writeWord(self.words.icsr, icsr | icsr_pendstset);
                self.pends += 1;
            }
        }
        if (next != csr) try core.writeWord(self.words.csr, next);
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
