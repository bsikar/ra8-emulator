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

const DualRig = struct {
    gpa: std.mem.Allocator,
    opened: ra8.session.harness.Harness,
    second: ra8.session.cpu1.bringup.Cpu1,
    recording: ra8.session.history_trail.Recording,

    pub fn open(self: *DualRig, gpa: std.mem.Allocator) !void {
        self.gpa = gpa;
        self.opened = try ra8.session.harness.open(gpa, std.testing.io, .{
            .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf",
        });
        errdefer self.opened.deinit();
        self.second = .{};
        try self.second.open(gpa, std.testing.io, std.Io.Dir.cwd(), &self.opened, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
        self.opened.state.edge.idle_skip = false;
        self.opened.state.edge.timebase.per_chunk = 64;
        self.opened.session().live.boundary.?.chunk = 64;

        const session = self.opened.session();
        try session.setRunBudget(.cpu0, 1);
        try session.setRunBudget(.cpu1, 1);
        _ = try session.run(.cpu0, .cont);

        const cpu0 = self.opened.primaryCpu();
        const cpu1 = self.second.cpu();
        self.recording = ra8.session.history_trail.Recording.init(gpa, .{ &cpu0.slots, &cpu1.slots }, &self.opened.state.cpu0.store.?);
        self.recording.arm();
    }

    pub fn deinit(self: *DualRig) void {
        self.recording.deinit();
        self.second.close(self.gpa);
        self.opened.deinit();
    }

    pub fn port(self: *DualRig) ra8.session.history_window_port.Port {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn position(self: *DualRig) ra8.session.history_window_port.Position {
        return self.opened.session().grid.?.at;
    }

    pub fn digest(self: *DualRig) ![32]u8 {
        var writer = std.Io.Writer.Allocating.init(self.gpa);
        defer writer.deinit();
        try self.opened.state.files.writeTo(&writer.writer);
        var out: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(writer.written(), &out, .{});
        return out;
    }

    const vtable: ra8.session.history_window_port.Port.VTable = .{
        .position = vPosition,
        .line = vLine,
        .cpu = vCpu,
        .step = vStep,
        .saveFull = saveFull,
        .restoreFull = restoreFull,
        .saveSide = saveSide,
        .loadSide = loadSide,
    };

    fn of(context: *anyopaque) *DualRig {
        return @ptrCast(@alignCast(context));
    }

    fn vPosition(context: *anyopaque) ra8.session.history_window_port.Position {
        return of(context).position();
    }

    fn vLine(context: *anyopaque) u32 {
        return of(context).position().branch;
    }

    fn vCpu(context: *anyopaque, core: ra8.session.history_window_port.Core) ?*ra8.session.history_window_port.Cpu {
        const self = of(context);
        return switch (core) {
            .cpu0 => self.opened.primaryCpu(),
            .cpu1 => self.second.cpu(),
        };
    }

    fn vStep(context: *anyopaque, core: ra8.session.history_window_port.Core) anyerror!void {
        const self = of(context);
        const session = self.opened.session();
        session.setReplaying(true);
        defer session.setReplaying(false);
        const ended = try session.run(switch (core) {
            .cpu0 => .cpu0,
            .cpu1 => .cpu1,
        }, .cont);
        if (ended != .count) return error.UnexpectedStop;
    }

    fn saveFull(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try of(context).opened.state.files.writeTo(writer);
    }

    fn restoreFull(context: *anyopaque, bytes: []const u8) anyerror!void {
        try of(context).opened.history().restoreBytes(bytes);
    }

    fn saveSide(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
        try of(context).opened.state.files.writeParts(writer, .{ .memory = false });
    }

    fn loadSide(context: *anyopaque, bytes: []const u8, board: bool) anyerror!void {
        try of(context).opened.state.files.readParts(bytes, .{ .memory = false, .board = board });
    }
};

test "live dual-core window stepi and reverse-stepi exactness across other core turn and board tick" {
    var rig: DualRig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var w = engine.ReverseWindow.init(std.testing.allocator, rig.port(), &rig.recording, &rig.opened.state.cpu0.store.?, 64 * 1024 * 1024);
    defer w.deinit();
    try w.plant();

    // Record slots across both cores
    for (0..40) |i| {
        const core: engine.Core = if (i % 3 == 0) .cpu1 else .cpu0;
        try ra8.session.history_window_record.recordSlot(&w, core);
    }

    // Verify both cores step forward and back with exact inverses
    for ([_]engine.Core{ .cpu0, .cpu1 }) |core| {
        try w.walkTo(0);
        _ = try step.stepForward(&w, core);
        var crossed_other = false;
        var crossed_complex = false;
        while (w.cursor() < w.count()) {
            const before = w.cursor();
            const digest_before = try rig.digest();
            const forward = try step.stepForward(&w, core);
            try std.testing.expect(w.cursor() > before);
            crossed_other = crossed_other or forward.other_core_slots > 0;
            crossed_complex = crossed_complex or forward.complex_slots > 0;
            if (forward.at_window_end) break;
            const back = try step.stepBack(&w, core);
            try std.testing.expectEqual(before, w.cursor());
            try std.testing.expectEqual(forward.other_core_slots, back.other_core_slots);
            try std.testing.expectEqual(forward.complex_slots, back.complex_slots);
            try std.testing.expectEqualSlices(u8, &digest_before, &try rig.digest());
            _ = try step.stepForward(&w, core);
        }
        try std.testing.expect(crossed_other);
    }
}

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) ra8.session.transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

test "dual-core stepping from last few slots inside window over its end lands on same stop and state as straight live run" {
    var rig: DualRig = undefined;
    try rig.open(std.testing.allocator);
    defer rig.deinit();

    var w = engine.ReverseWindow.init(std.testing.allocator, rig.port(), &rig.recording, &rig.opened.state.cpu0.store.?, 64 * 1024 * 1024);
    defer w.deinit();
    try w.plant();

    // Record 20 slots across both cores: slot 18 is cpu0, slot 19 is cpu1
    for (0..20) |i| {
        const core: engine.Core = if (i % 2 == 0) .cpu0 else .cpu1;
        try ra8.session.history_window_record.recordSlot(&w, core);
    }
    try std.testing.expectEqual(@as(usize, 20), w.count());

    // 1. Capture serialized state at window end (slot 20)
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer writer.deinit();
    try rig.opened.state.files.writeTo(&writer.writer);

    // 2. Straight live run: take a live step on cpu0 from slot 20
    _ = try rig.opened.session().run(.cpu0, .step);
    const expected_pos = rig.position();
    const expected_digest = try rig.digest();

    // 3. Restore state back to slot 20
    try rig.opened.history().restoreBytes(writer.written());

    // 4. Attach window to session and set up transport
    const session = rig.opened.session();
    session.attachWindow(&w);
    var t = ra8.session.transport.Transport{ .session = session };

    // 5. Walk to slot 19 (< 20). Slot 19 is cpu1, so cpu0 has no slots remaining in window.
    try w.walkTo(19);
    try std.testing.expectEqual(@as(usize, 19), w.cursor());

    // 6. Step cpu0: InsideWindow OutsideWindow triggers walkTo(20), redoing slot 19,
    // and then executes live session.run(.cpu0, .step).
    const ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .fwd } });
    var fake = FakeWall{};
    const ended = try t.finish(ticket, fake.wall(), null);
    try std.testing.expectEqual(ra8.session.api.Ended{ .stop = .stepped }, ended);

    // 7. Verify machine lands on exact same canonical stop and digest as straight live run
    try std.testing.expectEqual(expected_pos, rig.position());
    try std.testing.expectEqualSlices(u8, &expected_digest, &try rig.digest());
    try std.testing.expectEqual(@as(usize, 20), w.cursor());
}
