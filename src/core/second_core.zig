//! The second core: CPU1 put in front of the same board as CPU0.
//!
//! The RA8D2 carries two Cortex-M cores against ONE board. CPU0 comes out of
//! reset owning the part; CPU1 is started by CPU0 and, in every image in this
//! tree, runs as a permanent-Non-secure controller out of its own ELF. Up to
//! now this model could only step one of them, so the four dual-core images
//! ran with their second half missing: `cpu1_pingpong_ipc_cpu1` spun 799993
//! times on a semaphore nobody was ever going to release, and the run called
//! that a clean pass.
//!
//! TWO ENGINES, ONE BOARD, and that is the whole design. The second engine
//! is mapped onto the board RAM the first already owns
//! (`Engine.shareBoardRamWith`), so a store CPU1 makes in shared SRAM is
//! there for CPU0 with nothing in between, and it is attached to the SAME
//! peripheral bus, so IPCSEM and the IPC channels are one block that both
//! cores reach rather than two models kept in step. That is the point of the
//! pingpong app and it is what the silicon does.
//!
//! WHAT CPU0 KEEPS. Modelled time is charged once, by CPU0: it owns the time
//! base, the board tick and the interrupt controller, and CPU1 runs with
//! neither a clock of its own nor exception dispatch. Two cores charging the
//! same clocks would run modelled time at twice the rate for no reason, and
//! an NVIC per core is a real modelling decision this slice does not need to
//! make to get the handshake running. CPU1 therefore executes, reads and
//! writes, and reaches the same peripherals; it does not yet take
//! interrupts. Said plainly here so a later slice does not read the silence
//! as an oversight.
//!
//! WHAT CPU1 OWNS ALONE. The blocks on the bus are shared, but the windows
//! inside the core are not: a Cortex-M carries its own SAU, reached through
//! its own PPB, and two cores programme two different maps. CPU1 therefore
//! holds an SAU of its own here. Sharing one model let CPU1's bring-up land
//! on top of CPU0's: `cpu1_pingpong_ipc` programmes five regions and two
//! Non-Secure Callable entries on CPU0, and once its second half was mapped
//! the run reported five regions and NO callable entries, because CPU1 had
//! overwritten the first four with its own four. The count was right and
//! every value in it was wrong.
//!
//! THIS CORE IS NOT COPYABLE once it is open, and that is why `open` fills a
//! caller's `Second` in place instead of returning one. Its watch, its SAU
//! and its MPU guard are registered with Unicorn BY ADDRESS, so a `Second` returned by
//! value leaves both hooks pointing at the temporary they were taken from
//! and every record they make lands in freed memory.
//!
//! THE INTERLEAVE IS ROUND ROBIN at the chunk boundary: CPU0 runs a round,
//! then CPU1 runs a round, until CPU0's budget is spent or something ends
//! its run. It is not concurrency and does not pretend to be. What it buys
//! is the only thing the firmware actually needs: neither core can spin
//! forever without the other getting a turn, so a handshake completes.
const std = @import("std");
const engine = @import("engine.zig");
const elf = @import("elf.zig");
const memmap = @import("memmap.zig");
const cadence = @import("cadence.zig");
const sau = @import("../periph/sau.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const mpu_guard = @import("mpu_guard.zig");
const cpuid = @import("../periph/cpuid.zig");
const scb = @import("../periph/scb.zig");
const fault_clear = @import("../periph/fault_clear.zig");
const nvic = @import("../periph/nvic.zig");
const clocks = @import("../periph/clocks.zig");
const hint_resume = @import("hint_resume.zig");
const second_wait = @import("second_wait.zig");
const unmask = @import("unmask.zig");
const run_loop = @import("run_loop.zig");
const pend_break = @import("pend_break.zig");

const Board = @import("../board/board.zig").Board;
const wiring = @import("../board/wiring.zig");
const report_cores = @import("../interfaces/cli/report/cores.zig");
const Engine = engine.Engine;
const Guest = @import("cpu/memory/guest.zig").Guest;
const guest_load = @import("cpu/memory/load.zig");

/// CPU1's turn length against CPU0's round, from the CPU clock dividers.
pub const rate = @import("core_rate.zig");

pub const State = @import("second_state.zig").State;

/// VTOR resets to the core's initial vector base (CPU1INITVTOR for CPU1), not
/// to zero. The PPB is per-engine RAM here, so the word written lands in this
/// core's System Control Space only and CPU0's VTOR is left as it was.
pub fn primeVectorTable(memory: Guest, base: u32) !void {
    try memory.writeWord(memmap.scb.vtor, base);
}

/// What seeding CPU1's image left behind: bytes written and its table.
pub const Seeded = struct { written: u32, vector_base: u32 };

/// CPU1's image and VTOR, written into `memory` whichever backend holds it
/// (RA8EMU-571). The engine's own hooks for the image are the caller's.
pub fn seedImage(memory: Guest, image: elf.Image) !Seeded {
    const written = try guest_load.image(memory, image);
    const vector_base = image.vectorBase() orelse return error.NoVectorTable;
    try primeVectorTable(memory, vector_base);
    return .{ .written = written, .vector_base = vector_base };
}

pub const limits = struct {
    /// Instructions one core runs before the other gets its turn. The chunk
    /// boundary, so a round is one of CPU0's boundaries and the board ticks
    /// between turns rather than inside one.
    pub const round: u32 = cadence.instructions;

    /// Ceiling on a second core's image, the same one CPU0's loader uses.
    pub const image_bytes: usize = 64 * 1024 * 1024;
};

/// CPU1's per-core state beside CPU0's board. Its turns run on the Zig
/// core (second_zig_run.zig); `core` is only the engine a test lends it.
pub const Second = struct {
    core: Engine,
    /// What CPU1 has done and where it stands, apart from its engine.
    state: State = .{},
    watch: engine.Watch = .{},
    /// This core's own Security Attribution Unit. Core-private state, not a
    /// block on the shared bus: the header says what sharing one cost.
    partitions: sau.Sau = sau.Sau.init(),
    /// This core's own MPU table and the guard that enforces it, for the
    /// same reason: a Cortex-M's MPU sits behind its own PPB, so CPU0
    /// programming its regions must leave CPU1's untouched.
    regions: mpu.Mpu = mpu.Mpu.init(),
    guard: mpu_guard.Guard = mpu_guard.Guard.init(),
    /// CPU1's own AIRCR model: its PRIGROUP and its reset requests are its
    /// own, polled after each of its turns.
    control: scb.Scb = scb.Scb.init(),
    /// CPU1's own owed CFSR/HFSR clears, applied after each of its turns.
    clears: fault_clear.Clears = fault_clear.Clears.init(),
    /// A PendSV CPU1's own firmware writes ends CPU1's stretch, as CPU0's
    /// does: a suspend that lost its PendSV returned to the thread and
    /// `tx_thread_sleep` gave up with TX_CALLER_ERROR (RA8EMU-302).
    pend: pend_break.Pend = .{},
    /// CPU1's own mask release: a pend held by PRIMASK at a boundary is
    /// stepped to the instant the mask clears, as CPU0's is. Without it a
    /// masked spin whose length divides the turn (the module port's
    /// five-instruction `__tx_ts_wait`) meets every boundary masked and
    /// never takes its SysTick. src/core/unmask.zig.
    release: unmask.Release = .{},

    pub fn close(self: *Second) void {
        self.core.close();
    }

    /// A SYSRESETREQ from CPU1 is the part's one software reset: R01AN7883
    /// Table 11 lists a per-core watchdog, lockup and local-memory reset but
    /// a single "Software reset" (AIRCR.SYSRESETREQ), and 6.9 latches it in
    /// RSTSR1.SWRF. So it goes to the board exactly as CPU0's does
    /// (RA8EMU-59). `memory` is CPU1's own, where its AIRCR lives.
    pub fn takeResetRequest(self: *Second, memory: Guest) void {
        const asked = self.control.poll(memory) catch false;
        if (asked) if (self.state.board) |board| board.requestReset(.software);
    }
};

/// CPU1 on the Zig core, for --cpu zig (RA8EMU-234).
pub const zig = @import("second_zig.zig");

/// CPU1's half of a --cpu zig run (RA8EMU-234).
pub const zig_run = @import("second_zig_run.zig");

/// Parking in WFE, re-exported for the same reason.
pub const parking = second_wait;

/// What CPU1 did, printed under CPU0's own account of the run.
pub fn report(out: anytype, second: ?*const Second) !void {
    const other = second orelse return;
    try out.print(
        "CPU1: loaded {d} bytes, vectors at 0x{X:0>8}, ran {d} instructions over {d} turn(s), pc 0x{X:0>8}\n",
        .{ other.state.written, other.state.vector_base, other.state.ran, other.state.turns, other.state.pc },
    );
    if (other.state.fault) |taken| {
        try out.print("CPU1: halted at 0x{X:0>8}: {s}\n", .{ taken.pc, taken.detail });
    }
    if (other.state.held) try out.writeAll("CPU1: held in reset since a system reset\n");
    // Silent on a core that never waited, which is every image in the
    // corpus today, so their reports stay as they were.
    if (other.state.wait.parks > 0) {
        const woke = other.state.wait.wakes;
        try out.print(
            "CPU1: parked in WFE {d} time(s), woken {d} by an exception, {d} by SEV, {d} spuriously\n",
            .{ other.state.wait.parks, woke.interrupt, woke.event, woke.spurious },
        );
    }
    // Under its own name, because this is a second map rather than more
    // detail about CPU0's. Silent on a core that never programmed one.
    try report_cores.partitionsOf(out, "CPU1 SAU", &other.partitions);
}
