//! The round robin between CPU0 and CPU1.
//!
//! CPU0 runs a round, CPU1 takes a turn, and so on until CPU0's budget is
//! spent or one of the conditions `Engine.run` stops on is met. A round is
//! one of CPU0's chunk boundaries (`second_core.limits.round`). CPU1's turn
//! is that round scaled by the two CPU clock dividers (`Second.turn`), so a
//! CPU1 clocked at a quarter of CPU0 runs a quarter as many instructions.
//! Each core is charged for its own instructions on its own time base, and the order is
//! fixed, so the same pair of images interleaves the same way every run.
//! With no second core this is `Engine.run` and nothing else.

const engine = @import("engine.zig");
const second_core = @import("second_core.zig");
const Engine = engine.Engine;

/// Run CPU0 to its budget, giving CPU1 a turn between rounds.
///
/// With no second core this is `Engine.run` and nothing else, which is what
/// every single-core image gets: same call, same budget, same boundaries.
pub fn interleave(
    cpu0: Engine,
    entry: u32,
    budget: usize,
    session: engine.Session,
    second: ?*second_core.Second,
) engine.Error!?engine.Fault {
    const other = second orelse return cpu0.run(entry, budget, session);
    var pc = entry;
    var remaining = budget;
    while (remaining > 0) {
        const round = @min(@as(usize, second_core.limits.round), remaining);
        if (try cpu0.run(pc, round, session)) |taken| return taken;
        remaining -= round;
        pc = try cpu0.register(.pc);
        if (ended(cpu0, session)) break;
        other.step(other.turn(second_core.limits.round));
    }
    return null;
}

/// The conditions `Engine.run` itself stops a run on, re-read here because
/// the interleave calls it a round at a time and would otherwise hand the
/// same spent run another round.
fn ended(cpu0: Engine, session: engine.Session) bool {
    if (session.brk) |point| if (point.reached) return true;
    if (session.undefined_sites) |found| if (found.stoppedAt() != null) return true;
    if (session.stop) |watch| if (watch.met(cpu0.readWord(watch.address) catch null)) return true;
    if (session.deadline) |due| if (session.timebase) |clock| {
        if (due.met(clock.ticks)) return true;
    };
    return false;
}
