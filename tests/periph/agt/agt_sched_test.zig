//! Covers src/periph/agt/agt_sched.zig: the PCLKB the per-boundary step
//! stands for, and the virtual time a channel's next underflow is due at.
const std = @import("std");
const ra8 = @import("ra8");

const agt = ra8.periph.agt;
const sched = ra8.periph.agt_clock.sched;
const cadence = ra8.core.cadence;

/// One boundary of virtual time at the time base's default 1 GHz.
const boundary_ns: u64 = cadence.instructions;

fn started(counter: u16, mr1: u8) agt.Agt {
    var timer = agt.Agt.init();
    timer.channels[0].counter = counter;
    timer.channels[0].reload = 0xFFFF;
    timer.channels[0].mr1 = mr1;
    timer.channels[0].cr = agt.control.tstart;
    return timer;
}

/// The boundary the stepped model underflows channel 0 on.
fn steppedUnderflow(timer: *agt.Agt) u64 {
    var boundary: u64 = 1;
    while (boundary < 1000) : (boundary += 1) {
        timer.tick();
        if (timer.pending != 0) return boundary;
    }
    unreachable;
}

test "the step stands for 40.96 MHz of PCLKB" {
    try std.testing.expectEqual(@as(u64, 40_960_000), sched.pclkb_hz);
}

test "a queued underflow is due inside the boundary the step lands it on" {
    // Undivided, PCLKB/2 and PCLKB/8, from a count that spans boundaries.
    for ([_]u8{ 0x00, 0x30, 0x10 }) |mr1| {
        var timer = started(5000, mr1);
        const due = sched.dueAt(timer.channels[0], 0, 0).?;
        const landed = steppedUnderflow(&timer);
        try std.testing.expect(due > (landed - 1) * boundary_ns);
        try std.testing.expect(due <= landed * boundary_ns);
    }
}

test "a stopped or cascaded channel has nothing due" {
    var timer = started(100, 0x00);
    timer.channels[0].cr = 0;
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(timer.channels[0], 0, 0));
    timer = started(100, 0x50);
    timer.channels[1] = timer.channels[0];
    try std.testing.expectEqual(@as(?u64, null), sched.dueAt(timer.channels[1], 1, 0));
    // AGT0 cannot cascade, so the same byte counts undivided there.
    const undivided = ra8.periph.agt_clock.underflowInNs(100, .pclkb, sched.pclkb_hz).?;
    try std.testing.expectEqual(@as(?u64, 2_000_000 + undivided), sched.dueAt(timer.channels[0], 0, 2_000_000));
}
