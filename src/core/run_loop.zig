//! The run loop: how a run is cut into stretches of execution, and what
//! happens at the boundary between two of them.
//!
//! Its own file rather than another method on the engine, because the two are
//! different jobs. src/core/engine.zig is the Unicorn boundary: it maps
//! memory, moves registers and runs a bounded stretch. Nothing in here
//! touches C. What it owns is the POLICY over those stretches, which is the
//! part with the interesting decisions in it: how wide a stretch is allowed
//! to be, who gets to act when one ends, and which of the things that can cut
//! one short ends the run rather than merely the stretch.
//!
//! `core` is anything the engine is: it maps and reads words, runs a bounded
//! stretch and holds registers. Taking it as `anytype` rather than importing
//! the engine is what keeps this file off the engine's import cycle, and is
//! the same shape src/periph/clocks.zig already uses for the same reason.
const cadence = @import("cadence.zig");
const mask_pace = @import("mask_pace.zig");
const fault = @import("fault.zig");
const nvic = @import("../periph/nvic.zig");
const idle = @import("idle.zig");
const unmask = @import("unmask.zig");
const pend_break = @import("pend_break.zig");
const pend_pace = @import("pend_pace.zig");
const hotspots = @import("../debug/hotspots.zig");
const Session = @import("session.zig").Session;

/// Run a bounded number of instructions. A fault is a result, not a
/// crash: it comes back with the PC that took it.
///
/// With a time base attached the run is cut into chunks and the clocks
/// are charged one chunk of time per chunk of execution, which is what
/// keeps a firmware that waits on DWT_CYCCNT or on SysTick from spinning
/// out the whole budget in one loop. With a controller attached, each of
/// those boundaries is also where a pending exception is taken, and a
/// handler branching to its EXC_RETURN is unwound rather than reported:
/// Unicorn cannot fetch from 0xFFFFFFxx and does not have to.
pub fn run(core: anytype, start: u32, instructions: usize, session: Session) !?fault.Fault {
    if (session.watch) |w| w.clear();
    if (session.timebase == null and session.interrupts == null) {
        return core.runChunk(start, instructions, session.watch);
    }
    const configured = cadence.configuredFrom(
        session.per_boundary,
        if (session.timebase) |clock| clock.per_chunk else null,
    );
    var remaining = instructions;
    var pc = start;
    while (remaining > 0) {
        // Opening a stretch closes the one before it, so a pend that was
        // swallowed can be read against the boundary that failed to drain
        // it. src/core/pend_break.zig carries why that matters.
        if (session.pend) |pending| pending.boundary(pc);
        const pace = paceFor(core, configured, session);
        const chunk = pace.chunk(remaining);
        if (try stretch(core, pc, chunk, session)) |taken| {
            const controller = session.interrupts orelse return taken;
            if (!nvic.isExceptionReturn(taken.pc)) return taken;
            remaining -= try returned(core, controller, session, remaining, taken.pc);
            pc = try core.register(.pc);
            continue;
        }
        if (try interposed(core, session, &remaining, chunk)) |resumed| {
            pc = resumed;
            continue;
        }
        if (endsHere(session)) break;
        // The firmware armed or re-armed SysTick inside this stretch, so
        // the boundary it was cut from no longer applies and the periods
        // it would swallow are ones the firmware is owed. Charged one
        // instruction, the same as the traps above, and the next stretch
        // is cut from the period now armed.
        if (session.timebase) |clock| if (clock.took()) {
            remaining -= 1;
            pc = try core.register(.pc);
            continue;
        };
        remaining -= chunk;
        if (session.timebase) |clock| clock.advance(core, @intCast(chunk)) catch return error.RunFailed;
        // The budget is spent: do not enter a handler there is no room
        // left to run, which would report a run that ended inside an
        // exception it never actually took.
        if (!pace.closes(remaining)) break;
        if (session.board) |tick| tick.run(core) catch return error.RunFailed;
        // A part that just reset has nothing pending, so the controller
        // does not get to pick this boundary: carry straight on into the
        // reset vector.
        if (session.reboot) |pending| if (pending.requested) {
            pc = pending.perform(core, session.interrupts) catch return error.RunFailed;
            continue;
        };
        if (session.interrupts) |controller| {
            remaining -= service(core, controller, session, remaining) catch return error.RunFailed;
        }
        // The counter is read here, after the boundary's blocks have
        // run, so a value a peripheral advanced this chunk is seen.
        if (session.stop) |watch| if (watch.met(core.readWord(watch.address) catch null)) break;
        // Modelled time is read from the same boundary, after the counter:
        // when both land on one boundary the counter is the verdict the
        // suite asked for and the deadline is only the window it allowed.
        if (session.deadline) |due| if (session.timebase) |clock| {
            if (due.met(clock.ticks)) break;
        };
        pc = try core.register(.pc);
        // Sampled last, so the address recorded is the one the next
        // stretch starts at rather than whatever a handler left behind.
        if (session.pcs) |table| table.sample(pc);
        if (session.fns) |table| table.sample(pc);
    }
    return null;
}

/// Unwind a handler that branched to its EXC_RETURN, and tail-chain.
///
/// The stretch that ended in the return cannot be measured, so it is
/// charged one instruction: enough to keep the budget monotone and a bad
/// frame from looping forever. The tail chain is charged whatever its own
/// lift spent. Returns the whole charge.
fn returned(core: anytype, controller: anytype, session: Session, left: usize, from: u32) !usize {
    controller.exit(core, from) catch return error.RunFailed;
    const chain = tailChained(core, controller, session, left - 1) catch
        return error.RunFailed;
    return 1 + chain;
}

/// The exception that was still pending when a handler returned, entered
/// without going back to the interrupted code first.
///
/// WHY THIS EXISTS. The architecture tail-chains: at the end of a handler,
/// if another exception is pending and takeable, it is entered directly
/// (DDI0553 B3.14), without unstacking and restacking a frame the thread
/// would never have got to use. This model only dispatched at a run
/// boundary, so a second exception waited thousands of instructions, and
/// one of them never arrived at all.
///
/// Measured on `threadx_blink`: ThreadX gives SysTick and PendSV the same
/// lowest priority, so PendSV cannot preempt a running SysTick handler,
/// which is correct. But SysTick pends again every period, and every
/// boundary found it pending and took it, so the PendSV standing behind it
/// was outranked forever. Over 1000 modelled milliseconds the run entered
/// SysTick 999 times and PendSV four, and the scheduler ran four times when
/// the firmware asked for it eighteen times. Raising the unmask seam's step
/// bound from 64 to 4096 changed none of it, which is the signature of a
/// pend that is outranked rather than one that is masked.
///
/// Returns the instructions the lift inside it spent, which the caller owes
/// the budget. Entering a handler costs none of its own.
fn tailChained(core: anytype, controller: anytype, session: Session, left: usize) !usize {
    if (left == 0) return 0;
    const before = controller.taken;
    const lifted = try service(core, controller, session, left);
    if (controller.taken != before) controller.chained += 1;
    return lifted;
}

/// A pend the firmware wrote, taken at the store that wrote it.
///
/// The hook stopped the stretch on the store, so this is the boundary the
/// architecture would have put the handler at. How far into the stretch
/// the store happened cannot be measured, so the stretch is charged the
/// WHOLE chunk, the same approximation the idle seam already makes when
/// it skips one. Charging a single instruction instead, which is what the
/// trap path does, is wrong here for a reason the traps never hit: a trap
/// fires once, a pend fires in a loop. A firmware that pends on every
/// pass then runs a whole chunk of work for one instruction of budget and
/// one instruction of modelled time, so the deadline never arrives and
/// the run grinds. Measured that way, `threadx_canfd_demo` and
/// `wdt_supervisor_demo` stopped finishing at all. The cost of the other
/// choice is that modelled time runs at most one boundary ahead of the
/// work per pend, which on `threadx_blink` is 68 boundaries over 100
/// periods of a 99-million-cycle run.
///
/// Returns where to resume, or null when nothing was latched.
fn servedPend(core: anytype, session: Session, remaining: *usize, chunk: usize) !?u32 {
    const pending = session.pend orelse return null;
    if (!pending.take()) return null;
    remaining.* -= chunk;
    if (session.timebase) |clock| clock.advance(core, @intCast(chunk)) catch return error.RunFailed;
    if (session.interrupts) |controller| {
        remaining.* -= service(core, controller, session, remaining.*) catch return error.RunFailed;
    }
    return try core.register(.pc);
}

/// The three things that can end a stretch before its chunk runs out and
/// hand execution straight back, in the order they are allowed to.
///
/// All three are boundaries the firmware made rather than ones the clock
/// made, so none of them charges a chunk: a trap and a second look cost one
/// instruction, and a raised pend charges the chunk it cut because it also
/// moves the clocks. Returns where to resume, or null when the stretch
/// simply ran to its end.
fn interposed(core: anytype, session: Session, remaining: *usize, chunk: usize) !?u32 {
    if (try trapped(core, session)) |resumed| {
        remaining.* -= 1;
        return resumed;
    }
    if (try servedPend(core, session, remaining, chunk)) |resumed| return resumed;
    return try lookedAgain(core, session, remaining);
}

/// The firmware asked again, from Thread mode, for a switch it is still
/// owed, so the controller gets another look at the pend already standing.
///
/// Charged one instruction and NOT a chunk, the same as a trap and an
/// exception return, because nothing was raised here. The bit was already
/// up; all this boundary buys is a chance to dispatch it. Advancing the
/// clocks by a chunk would invent modelled time the firmware never spent,
/// and at a hundred and fifty of these a second that is a visible lie.
/// src/core/pend_break.zig carries why the look is owed at all.
fn lookedAgain(core: anytype, session: Session, remaining: *usize) !?u32 {
    const pending = session.pend orelse return null;
    if (!pending.lookAgain()) return null;
    remaining.* -= 1;
    if (session.interrupts) |controller| {
        remaining.* -= service(core, controller, session, remaining.*) catch return error.RunFailed;
    }
    return try core.register(.pc);
}

/// A store into a read-only region that stopped the chunk early, turned
/// into the exception it should have raised.
///
/// Taken here, at the boundary the trap made, before the clocks are
/// charged for a chunk that did not finish. Returns where to resume, or
/// null when no trap was latched. The caller charges the stretch one
/// instruction for the same reason an exception return is charged one:
/// enough to keep the budget monotone and a bad frame from looping
/// forever.
fn trapped(core: anytype, session: Session) !?u32 {
    const guard = session.protection orelse return null;
    const hit = guard.latch.take() orelse return null;
    guard.synthesise(core, session.interrupts, hit) catch return error.RunFailed;
    return try core.register(.pc);
}

/// Execute one stretch of a run.
///
/// Without an idle seam this is the bounded stretch and nothing else. With
/// one it is the same stretch in two parts: the head is stepped looking for
/// a loop that comes back to its own opening state, and if one closes, the
/// tail is handed to the clocks without being executed. The caller is told
/// nothing about which happened, because nothing downstream differs: the
/// budget falls by the whole chunk either way and the clocks are charged
/// the whole chunk either way, so the interrupt that ends the spin arrives
/// at the modelled time it always would have.
fn stretch(core: anytype, pc: u32, chunk: usize, session: Session) !?fault.Fault {
    const seam = session.idle orelse return core.runChunk(pc, chunk, session.watch);
    // Already proved, and still standing in the same place: the common case
    // once a run goes idle, and the one that has to stay cheap.
    if (try seam.resting(core)) {
        seam.skip(chunk);
        return null;
    }
    const looked = try seam.look(core, pc, @min(chunk, idle.limits.probe));
    if (looked.fault) |taken| return taken;
    if (looked.closed) {
        seam.skip(chunk - looked.ran);
        return null;
    }
    if (askedToStop(session)) return null;
    if (looked.ran >= chunk) return null;
    return core.runChunk(try core.register(.pc), chunk - looked.ran, session.watch);
}

/// Did the pend hook ask for this stretch to end while the probe was still
/// stepping the head of it?
///
/// WHY THE STRETCH WOULD END HERE. The probe single-steps, and inside a
/// one-instruction run a hook's request to stop buys nothing: the run was
/// ending after that instruction anyway. src/core/idle.zig ends the PROBE
/// at the disturbance, which is the first half. This is the second: without
/// it the probe hands back after two or three instructions and the tail of
/// the chunk is run anyway, so the thread carries straight on past the
/// store it just pended at, and the next pend store overwrites the address
/// the first one recorded. On `threadx_blink` with `--drain-pends` that was
/// 20002 stops asked for against 10002 reaching a boundary, exactly one per
/// stretch lost. Honouring it takes the swallowed pends from 10000 to 1 and
/// the overwritten stops from 10000 to 1.
///
/// `ended` is the hook's own flag, cleared at every boundary before the
/// stretch opens, so reading it asks only about THIS stretch. It covers
/// both reasons the hook stops, a pend it raised and a second look at one
/// already standing: both leave the program counter on the store and both
/// want the same boundary.
///
/// BEHIND THE EXPERIMENT FLAG, and that is a finding rather than caution.
/// Ungated, this is not confined to the `--drain-pends` path, because the
/// hook sets `ended` for a pend it RAISED too, and that happens with the
/// flag off. Two images move when it does, measured over 200 modelled ms
/// against the tip: `threadx_canfd_demo` goes from 206 exceptions taken to
/// 3202 and from 199 proved closures to 50, and `wdt_supervisor_demo` goes
/// from 296 watchdog refreshes to 2. Both stop reaching the modelled
/// deadline and run their instruction budget out instead. The direction is
/// not obviously wrong, since a pend taken at its store is what the
/// architecture does, but there is no board reading in this tree that says
/// 3202 is nearer the truth than 206, and a supervisor that refreshes its
/// watchdog twice in 200 ms is a reason to look rather than a result to
/// ship. So it rides the switch that already carries this experiment, the
/// default path stays bit-identical across all 36 images, and the next
/// slice can judge the ungated version against a board.
///
/// Nothing is charged here: the caller's `interposed` charges a raised pend
/// the whole chunk, the way it already does for a stop that lands in the
/// tail, and charges a second look one instruction.
pub fn askedToStop(session: Session) bool {
    const pending = session.pend orelse return false;
    if (!pending.look.cuts()) return false;
    return pending.ended;
}

/// Take what the boundary owes: a pend that has been waiting out a mask,
/// then the exception itself. Reports the instructions the lift charged.
///
/// The seam is stirred whenever a handler is actually entered, because a
/// handler is the one thing that can write the word an idle spin is
/// waiting on and then return leaving that spin's registers exactly as it
/// found them. src/core/idle.zig carries why that matters.
fn service(core: anytype, controller: anytype, session: Session, remaining: usize) !usize {
    const lifted = try liftMask(core, controller, session, remaining);
    // Read before dispatching: once the vector is entered the program
    // counter is the handler's, and the question is what it interrupted.
    const asked = session.taken_from != null or session.taken_in != null;
    const interrupted = if (asked) try core.register(.pc) else 0;
    const entered = try controller.dispatch(core);
    if (entered) |number| {
        if (session.taken_from) |counted| counted.record(interrupted, number);
        if (session.taken_in) |window| window.record(interrupted, number);
    }
    if (entered != null) if (session.idle) |seam| seam.stir();
    return lifted;
}

/// Let a pend that is ready but masked wait out the mask, and report the
/// instructions that cost.
///
/// The controller can only take an exception at a boundary, so a pend that
/// lands inside a `cpsid i` region would be counted as held and not offered
/// again until the next period. The architecture takes it the instant the
/// mask clears, so the boundary steps there. The instructions are charged to
/// the clocks here and returned so the caller can charge the budget too:
/// they are ordinary executed instructions and modelled time has to keep
/// matching the work done. Bounded by the budget left as well as by the
/// seam's own cap, so the return can never exceed what the caller has.
fn liftMask(core: anytype, controller: anytype, session: Session, remaining: usize) !usize {
    const seam = session.unmask orelse return 0;
    if (!(try controller.pendingMasked(core))) {
        try seam.nothingMasked(core);
        return 0;
    }
    const lifted = try seam.lift(core, @min(remaining, unmask.limits.steps));
    if (lifted.ran == 0) return 0;
    if (session.timebase) |clock| try clock.advance(core, @intCast(lifted.ran));
    return lifted.ran;
}

/// The boundary this stretch gets. The armed period is read every time
/// round rather than once: the firmware arms SysTick well after reset,
/// and may re-arm it.
fn paceFor(core: anytype, configured: cadence.Cadence, session: Session) cadence.Cadence {
    var pace = configured;
    if (session.timebase) |clock| pace = pace.narrowedTo(clock.period(core));
    pace = whileStanding(pace, session);
    // Narrowed again while a masked pend keeps coming back stuck, so the
    // mask is re-tested within a couple of thousand instructions instead
    // of a whole chunk. Off unless asked for: src/core/mask_pace.zig
    // carries the measurement that says it recovers nothing.
    if (session.mask_pace) |tracker| if (session.unmask) |seam| {
        pace = .{ .per_boundary = tracker.widthFor(pace.per_boundary, seam.run) };
    };
    return pace;
}

/// Narrow this boundary while a pend the firmware wrote is still standing
/// unserved, so the controller is asked again within a couple of thousand
/// instructions instead of a whole chunk.
///
/// Read off the controller's own run of unserved boundaries, which the
/// boundary just passed updated, so a pend that was entered puts the width
/// straight back. Nothing is forced and no time is invented: the stretch
/// is charged the instructions it actually runs, the same as any other.
/// src/core/pend_pace.zig carries why the boundary is the thing to shorten
/// and `--drain-pends` is not.
fn whileStanding(pace: cadence.Cadence, session: Session) cadence.Cadence {
    const tracker = session.pend_pace orelse return pace;
    const controller = session.interrupts orelse return pace;
    return .{ .per_boundary = tracker.widthFor(pace.per_boundary, controller.standing.run) };
}

/// A hook that stopped the chunk on its own instruction rather than at a
/// boundary, which ends the run here: this is where the program counter
/// still points at it and the register file is the caller's. The break
/// stops on the break itself; the undefined hook one instruction before
/// the encoding runs.
pub fn endsHere(session: Session) bool {
    if (session.brk) |point| if (point.reached) return true;
    if (session.undefined_sites) |f| if (f.stoppedAt() != null) return true;
    return false;
}
