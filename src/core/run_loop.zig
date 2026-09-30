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
const fault = @import("fault.zig");
const nvic = @import("../periph/nvic.zig");
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
    const configured = cadence.Cadence{
        .per_boundary = if (session.timebase) |clock| clock.per_chunk else cadence.instructions,
    };
    var remaining = instructions;
    var pc = start;
    while (remaining > 0) {
        const pace = paceFor(core, configured, session);
        const chunk = pace.chunk(remaining);
        if (try core.runChunk(pc, chunk, session.watch)) |taken| {
            const controller = session.interrupts orelse return taken;
            if (!nvic.isExceptionReturn(taken.pc)) return taken;
            controller.exit(core, taken.pc) catch return error.RunFailed;
            pc = try core.register(.pc);
            // The stretch that ended in the return cannot be measured, so
            // it is charged one instruction: enough to keep the budget
            // monotone and a bad frame from looping forever.
            remaining -= 1;
            continue;
        }
        // A store into a read-only region stopped the chunk early, so the
        // exception is taken here, at the boundary the trap made, before
        // the clocks are charged for a chunk that did not finish. The
        // stretch is charged one instruction for the same reason the
        // exception return above is: enough to keep the budget monotone.
        if (session.protection) |guard| if (guard.latch.take()) |hit| {
            guard.synthesise(core, session.interrupts, hit) catch return error.RunFailed;
            remaining -= 1;
            pc = try core.register(.pc);
            continue;
        };
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
        if (session.interrupts) |controller| _ = controller.dispatch(core) catch return error.RunFailed;
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
    }
    return null;
}

/// The boundary this stretch gets. The armed period is read every time
/// round rather than once: the firmware arms SysTick well after reset,
/// and may re-arm it.
fn paceFor(core: anytype, configured: cadence.Cadence, session: Session) cadence.Cadence {
    const clock = session.timebase orelse return configured;
    return configured.narrowedTo(clock.period(core));
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
