//! Whether a stretch of execution can change anything at all.
//!
//! WHY THIS EXISTS. The suite drives this emulator with windows measured in
//! seconds, and the model charges one cycle per instruction, so a modelled
//! second costs as many instructions as the firmware's clock has hertz.
//! `k_ra8_cpuclk0_hz` is a gigahertz, so a four second probe window on an
//! image that finishes CGC bring-up is four billion instructions. Measured
//! on this corpus: `threadx_blink` spends 519 seconds of wall time and does
//! not reach its window, while `blink`, which never leaves the source it
//! resets on, passes its own in two. The split is not slow images against
//! fast ones; it is images that brought the PLL up against images that did
//! not, and it is two and a half orders of magnitude.
//!
//! Almost all of that budget goes into a spin. ThreadX idles in
//! `__tx_ts_wait`, six instructions that reload `_tx_thread_execute_ptr`,
//! store it over `_tx_thread_current_ptr` and branch back. Nothing in the
//! loop can make it exit. Only the SysTick handler can, and in this model a
//! handler runs at a chunk boundary, so every instruction between two
//! boundaries is known in advance to be wasted. There is no WFI to key on:
//! the loop is an ordinary branch, which is why nothing accelerates it today.
//!
//! WHAT IS PROVED, not guessed. A stretch is skipped only after the machine
//! has been stepped back to a state IDENTICAL to the one it started in: the
//! whole general register file, both stack pointers, the flags, and every
//! word that masks interrupts. A loop that returns to its own first
//! instruction with all of that unchanged will do so again, forever, until
//! something outside it intervenes. The skipped instructions are still
//! CHARGED to the clocks, so modelled time is untouched and the interrupt
//! that ends the spin arrives exactly when it would have: what is dropped is
//! the executing, never the time.
//!
//! MEMORY IS THE HOLE A REGISTER COMPARISON LEAVES, and it is not
//! hypothetical: `__tx_ts_wait` stores on every pass. A loop can restore
//! every register and still walk a counter in RAM, and on this corpus that
//! counter is frequently the very symbol the probe contract reads. So a
//! store during the probe disturbs the seam unless the model can see it
//! changed nothing: a store into ordinary RAM that writes back the value
//! already there is harmless, and a store anywhere else is not, because a
//! peripheral register can act on a write whose read-back never moves.
//! src/core/idle_hook.zig is the half that watches for it.
//!
//! `core` is taken as `anytype` for the reason src/core/run_loop.zig takes
//! it that way: it keeps this file off the engine's import cycle, and
//! nothing here touches C.
const std = @import("std");
const fault = @import("fault.zig");
const board_ram = @import("board_ram.zig");

pub const limits = struct {
    /// Instructions a closure probe may step before giving up. Small on
    /// purpose: a stretch that is NOT idle pays this many single steps at
    /// every boundary, and an idle loop is a handful of instructions wide.
    /// ThreadX's is six and the widest this corpus shows is under twenty.
    pub const probe: usize = 64;
    /// Words in a snapshot: r0 through r12, both stack pointers and the
    /// one in use, the link register, the program counter, the flags, and
    /// the four words that mask or select interrupts.
    pub const watched: usize = 23;
};

/// The registers a closed loop has to come back to, in the order a
/// snapshot fills them.
const order = .{
    .r0,  .r1,  .r2,   .r3,      .r4,        .r5,      .r6,
    .r7,  .r8,  .r9,   .r10,     .r11,       .r12,     .sp,
    .lr,  .pc,  .xpsr, .primask, .faultmask, .basepri, .control,
    .msp, .psp,
};

/// One reading of the whole architectural state.
pub const State = struct {
    regs: [limits.watched]u32 = @splat(0),

    pub fn same(self: State, other: State) bool {
        return std.mem.eql(u32, &self.regs, &other.regs);
    }
};

/// Read the machine. Twenty-three register reads, which is nothing beside
/// the tens of thousands of instructions a boundary otherwise carries.
pub fn snapshot(core: anytype) !State {
    var out = State{};
    inline for (order, 0..) |which, index| {
        out.regs[index] = try core.register(which);
    }
    return out;
}

/// What a probe found.
pub const Look = struct {
    /// Instructions actually stepped, which the caller still owes the
    /// clocks whether or not the loop closed.
    ran: usize = 0,
    /// The machine came back to the state it started in and nothing it did
    /// on the way can be seen from outside it.
    closed: bool = false,
    /// A step faulted. The probe stops there and the caller handles it the
    /// way it handles a fault in any other stretch.
    fault: ?fault.Fault = null,
};

/// Does a store at this address land in ordinary RAM, where writing back
/// the value already there changes nothing?
///
/// The PPB is deliberately NOT ordinary here even though the board maps it
/// as RAM: SysTick, the NVIC and the SCB answer on it, and several of their
/// registers act on a write whose read-back does not move.
pub fn plainMemory(address: u64, size: u32) bool {
    if (address > std.math.maxInt(u32)) return false;
    const base: u32 = @truncate(address);
    if (base >= 0xE000_0000) return false;
    return board_ram.covers(base, size);
}

/// The seam itself: what it has proved, and what it saved.
pub const Seam = struct {
    /// Raised only for the length of a probe, so the write hook costs a
    /// compare and a return everywhere else.
    armed: bool = false,
    /// Set by the hook when a store during a probe did something the model
    /// cannot show was harmless.
    disturbed: bool = false,
    /// The state the machine was last proved idle in. Held so a run that
    /// stays idle across many boundaries pays one snapshot each rather
    /// than a fresh probe.
    known: ?State = null,
    /// Loops proved closed.
    closures: u64 = 0,
    /// Boundaries whose stretch was charged without being executed.
    boundaries: u64 = 0,
    /// Instructions charged to the clocks and never executed.
    skipped: u64 = 0,

    /// Called by the hook. Anything it cannot show harmless lands here.
    pub fn disturb(self: *Seam) void {
        self.disturbed = true;
    }

    /// Is the machine still in the state a probe already proved closed?
    /// One snapshot, no stepping: this is the case that carries a long
    /// idle stretch, so it has to be the cheap one.
    pub fn resting(self: *Seam, core: anytype) !bool {
        const held = self.known orelse return false;
        const now = try snapshot(core);
        if (now.same(held)) return true;
        self.known = null;
        return false;
    }

    /// Step the head of a stretch looking for a loop that closes on itself.
    ///
    /// Single steps rather than one bounded run, because the answer needed
    /// is "did the machine return to this exact state", and a run of a
    /// fixed count lands wherever the loop's length leaves it. A loop of
    /// length L closes within L steps, so the budget bounds the loop width
    /// this can see rather than the work it does on an idle machine.
    pub fn look(self: *Seam, core: anytype, pc: u32, budget: usize) !Look {
        const opening = try snapshot(core);
        self.disturbed = false;
        self.armed = true;
        defer self.armed = false;
        var ran: usize = 0;
        var at = pc;
        while (ran < budget) {
            if (try core.runChunk(at, 1, null)) |taken| {
                return .{ .ran = ran, .fault = taken };
            }
            ran += 1;
            const now = try snapshot(core);
            if (now.same(opening)) {
                if (self.disturbed) return .{ .ran = ran };
                self.closures += 1;
                self.known = opening;
                return .{ .ran = ran, .closed = true };
            }
            at = try core.register(.pc);
        }
        return .{ .ran = ran };
    }

    /// Forget a proof an outside event has just invalidated.
    ///
    /// `resting` compares registers, and that is the whole proof only while
    /// nothing outside the loop writes the memory the loop READS. An
    /// exception handler breaks both halves of that at once: it can store
    /// the very word the spin is waiting on, and it returns leaving the
    /// spin's registers exactly as it found them, so the snapshot still
    /// matches a state that has stopped being idle. The header above says
    /// the proof holds until something outside intervenes; this is how the
    /// seam is told that it did.
    ///
    /// Measured on `threadx_blink`, where `__tx_ts_wait` waits on
    /// `_tx_thread_execute_ptr` and a handler is the only thing that ever
    /// sets it: without this the seam went on skipping the loop after the
    /// word went non-zero, and the image never ran a thread again.
    ///
    /// NOT COVERED, deliberately: a peripheral that writes RAM on its own,
    /// a DMA transfer landing in a buffer a spin polls, is the same shape
    /// and is not stirred here. The boundary's peripheral blocks run every
    /// time round, so treating them as intervention would retire the seam
    /// altogether, and no image in this corpus waits on one.
    pub fn stir(self: *Seam) void {
        self.known = null;
    }

    /// Charge a stretch nobody has to execute.
    pub fn skip(self: *Seam, instructions: usize) void {
        if (instructions == 0) return;
        self.boundaries += 1;
        self.skipped += instructions;
    }
};
