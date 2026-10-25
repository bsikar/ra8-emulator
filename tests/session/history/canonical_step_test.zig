//! Canonical stepi and reverse-stepi tests on a reverse window: the two
//! are exact inverses between canonical stops, the other core's turn and
//! a board tick are crossed in one step, and a step that needs a slot
//! outside the window refuses without moving anything.
//!
//! The rig runs one core, so the test hands the window's recorded slots
//! to CPU1 in turns (RAM/CPU slots only: their walk never reads the tag)
//! to stand in for the other core's turn between CPU0's slots.

const std = @import("std");
const ra8 = @import("ra8");
const rig_mod = @import("window_rig.zig");
const engine = ra8.session.history_window_engine;
const rebuild = ra8.session.history_window_rebuild;
const step = ra8.session.history_canonical_step;

const slots: usize = 160;

fn built(rig: *rig_mod.Rig, straight: *const rig_mod.Straight) !engine.ReverseWindow {
    try rig.port().restoreFull(straight.base);
    var w = rig.window(64 * 1024 * 1024);
    errdefer w.deinit();
    try rebuild.run(&w, .{ .base = .{ .bytes = straight.base }, .end = straight.positions[slots] });
    return w;
}

/// Every fifth slot, and the one after it, are CPU1's turn.
fn handOutTurns(w: *engine.ReverseWindow) void {
    for (0..w.count()) |i| {
        const slot = w.slotAt(i);
        if (i % 5 >= 3 and slot.kind == .ram_cpu) slot.core = .cpu1;
    }
}

test "stepi then reverse-stepi returns to the same canonical stop on either core" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();
    var w = try built(&rig, &straight);
    defer w.deinit();
    handOutTurns(&w);

    for ([_]engine.Core{ .cpu0, .cpu1 }) |core| {
        try w.walkTo(0);
        // Inverses hold between canonical stops: start on one of `core`.
        _ = try step.stepForward(&w, core);
        var crossed_other = false;
        for (0..20) |_| {
            const before = w.cursor();
            const digest = try rig.digest();
            const forward = try step.stepForward(&w, core);
            try std.testing.expect(w.cursor() > before);
            crossed_other = crossed_other or forward.other_core_slots > 0;
            // The next slot of `core` starts here, or the window ends.
            if (!forward.at_window_end) try std.testing.expect(w.slotAt(w.cursor()).core == core);
            try std.testing.expectEqualSlices(u8, &straight.digests[w.cursor()], &try rig.digest());
            const back = try step.stepBack(&w, core);
            try std.testing.expectEqual(forward.other_core_slots, back.other_core_slots);
            try std.testing.expectEqual(before, w.cursor());
            try std.testing.expectEqualSlices(u8, &digest, &try rig.digest());
            _ = try step.stepForward(&w, core);
        }
        try std.testing.expect(crossed_other);
    }
}

test "a step across a board tick reports the tick and lands on the straight run" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();
    var w = try built(&rig, &straight);
    defer w.deinit();

    // With every slot CPU0's, a step is one slot; a complex slot is a tick.
    var ticks: usize = 0;
    while (w.cursor() > 0) _ = try w.undo();
    while (w.cursor() < w.count()) {
        const forward = try step.stepForward(&w, .cpu0);
        ticks += forward.complex_slots;
        try std.testing.expectEqualSlices(u8, &straight.digests[w.cursor()], &try rig.digest());
        if (forward.complex_slots > 0) {
            const at = w.cursor();
            const back = try step.stepBack(&w, .cpu0);
            try std.testing.expectEqual(forward.complex_slots, back.complex_slots);
            try std.testing.expectEqualSlices(u8, &straight.digests[at - 1], &try rig.digest());
            _ = try step.stepForward(&w, .cpu0);
        }
    }
    try std.testing.expect(ticks > 0);
}

test "a step that needs a slot outside the window refuses and moves nothing" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();
    var w = try built(&rig, &straight);
    defer w.deinit();

    // The cursor stands at the end: no slot ahead, and none of CPU1's behind.
    const digest = try rig.digest();
    try std.testing.expectError(step.Error.OutsideWindow, step.stepForward(&w, .cpu0));
    try std.testing.expectError(step.Error.OutsideWindow, step.stepBack(&w, .cpu1));
    try std.testing.expectEqual(w.count(), w.cursor());
    try std.testing.expectEqualSlices(u8, &digest, &try rig.digest());

    try w.walkTo(0);
    try std.testing.expectError(step.Error.OutsideWindow, step.stepBack(&w, .cpu0));
    try std.testing.expectEqual(@as(usize, 0), w.cursor());
}

test "a step crosses a SysTick/board-tick gap and the other core's turn behind it as one stop" {
    var rig: rig_mod.Rig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();
    var straight = try rig_mod.Straight.record(&rig, slots);
    defer straight.deinit();
    var w = try built(&rig, &straight);
    defer w.deinit();

    // The round end is the tick slot (complex, where SysTick and the board
    // tick); CPU1's turn follows it before CPU0's next slot: the gap the
    // canonical stop must span.
    var gaps: usize = 0;
    for (0..w.count() - 3) |i| {
        if (w.slotAt(i).kind != .complex) continue;
        for (i + 1..i + 3) |k| {
            if (w.slotAt(k).kind == .ram_cpu) w.slotAt(k).core = .cpu1;
        }
    }
    try w.walkTo(0);
    _ = try step.stepForward(&w, .cpu0);
    while (w.cursor() < w.count()) {
        const before = w.cursor();
        const forward = try step.stepForward(&w, .cpu0);
        try std.testing.expectEqualSlices(u8, &straight.digests[w.cursor()], &try rig.digest());
        if (forward.complex_slots > 0 and forward.other_core_slots > 0) gaps += 1;
        if (forward.at_window_end) break;
        const back = try step.stepBack(&w, .cpu0);
        try std.testing.expectEqual(before, w.cursor());
        try std.testing.expectEqual(forward.complex_slots, back.complex_slots);
        try std.testing.expectEqual(forward.other_core_slots, back.other_core_slots);
        _ = try step.stepForward(&w, .cpu0);
    }
    try std.testing.expect(gaps > 0);
}
