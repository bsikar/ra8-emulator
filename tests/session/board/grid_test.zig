//! Valid-enum scheduler and joint-turn corruption must be refused atomically,
//! and every state a round can stop in must still load.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("state_fixture.zig");
const Harness = ra8.session.harness.Harness;
const Cpu1 = ra8.session.cpu1.bringup.Cpu1;
const State = ra8.chip.core.scheduler.State;

/// Offsets in the version 12, 63-byte grid payload.
const at = struct {
    pub const r = 4;
    pub const phase = 12;
    pub const o = 13;
    pub const base0 = 27;
    pub const cpu1_slots = 47;
    pub const cut = 51;
};

fn capture(h: *Harness) !std.Io.Writer.Allocating {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer writer.deinit();
    try h.state.files.writeTo(&writer.writer);
    return writer;
}

/// `before` with `payload` as its `kind` section is refused, and the machine
/// recaptures byte for byte as it was.
fn refused(h: *Harness, before: []const u8, kind: anytype, payload: []const u8) !void {
    var bad = try fixture.replacement(before, kind, payload);
    defer bad.deinit();
    try refusedFile(h, before, bad.written());
}

fn refusedFile(h: *Harness, before: []const u8, bad: []const u8) !void {
    try std.testing.expectError(error.BadValue, h.state.files.readFrom(bad));
    var after = try capture(h);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before, after.written());
}

/// The same edit is a state a round can stop in: it loads, and the machine
/// recaptures exactly what it was given.
fn accepted(h: *Harness, before: []const u8, kind: anytype, payload: []const u8) !void {
    var good = try fixture.replacement(before, kind, payload);
    defer good.deinit();
    try h.state.files.readFrom(good.written());
    var after = try capture(h);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, good.written(), after.written());
}

/// A single-core run stopped 37 slots into a 64-slot interval.
fn openSingle() !Harness {
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/threadx/threadx_stkof.elf", .history_frames = 2 });
    errdefer h.deinit();
    h.state.edge.idle_skip = false;
    h.state.edge.timebase.per_chunk = 64;
    h.session().live.boundary.?.chunk = 64;
    try h.session().setRunBudget(.cpu0, 37);
    _ = try h.session().run(.cpu0, .cont);
    return h;
}

const Case = struct { name: []const u8, state: State, ok: bool };

fn with(base: State, comptime field: []const u8, value: @FieldType(State, field)) State {
    var out = base;
    @field(out, field) = value;
    return out;
}

test "grid repair G5 scalar states a round can stop in are valid and no others" {
    const open: State = .{ .stretch = .{ .carry = 37, .full = 64 }, .lengths = .{ 37, 0 }, .at = .{ .o = 37 } };
    const spent: State = .{ .stretch = .{ .carry = 64, .full = 64 }, .lengths = .{ 37, 0 }, .at = .{ .phase = .cpu1 } };
    const ran: State = with(spent, "lengths", .{ 37, 5 });
    const cases = [_]Case{
        .{ .name = "root", .state = .{}, .ok = true },
        .{ .name = "cpu0 partial", .state = open, .ok = true },
        .{ .name = "cpu0 partial cut", .state = with(open, "cut", true), .ok = true },
        .{ .name = "last countable round", .state = with(open, "at", .{ .r = std.math.maxInt(u64) - 1, .o = 37 }), .ok = true },
        .{ .name = "cpu1 turn not opened", .state = spent, .ok = true },
        .{ .name = "cpu1 partial", .state = with(ran, "at", .{ .phase = .cpu1, .o = 5, .gap = .polled }), .ok = true },
        .{ .name = "board after spent interval", .state = with(ran, "at", .{ .phase = .board }), .ok = true },
        .{ .name = "board after cut", .state = with(with(open, "cut", true), "at", .{ .phase = .board }), .ok = true },
        .{ .name = "board before interval is spent", .state = with(open, "at", .{ .phase = .board }), .ok = false },
        .{ .name = "cpu1 before interval is spent", .state = with(open, "at", .{ .phase = .cpu1 }), .ok = false },
        .{ .name = "cpu1 after cut", .state = with(spent, "cut", true), .ok = false },
        .{ .name = "cpu0 with cpu1 slots", .state = with(open, "lengths", .{ 37, 1 }), .ok = false },
        .{ .name = "cut with no interval", .state = .{ .cut = true }, .ok = false },
        .{ .name = "cut without elapsed time", .state = .{ .stretch = .{ .full = 64 }, .cut = true }, .ok = false },
        .{ .name = "cut with peer slots", .state = with(with(ran, "cut", true), "at", .{ .phase = .board }), .ok = false },
        .{ .name = "round that cannot count on", .state = with(open, "at", .{ .r = std.math.maxInt(u64), .o = 37 }), .ok = false },
        .{ .name = "board polled gap", .state = with(spent, "at", .{ .phase = .board, .gap = .polled }), .ok = false },
        .{ .name = "cpu1 offset off its slots", .state = with(spent, "at", .{ .phase = .cpu1, .o = 1 }), .ok = false },
    };
    for (cases) |case| {
        std.debug.print("CHECK=G5 state '{s}' valid={} want={}\n", .{ case.name, case.state.valid(), case.ok });
        try std.testing.expectEqual(case.ok, case.state.valid());
    }
}

test "grid repair G5 valid enum premature board and overflow are atomic refusals" {
    var h = try openSingle();
    defer h.deinit();
    var before = try capture(&h);
    defer before.deinit();
    const payload = (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?.payload;
    try std.testing.expectEqual(@as(u32, 64), h.state.edge.saved.stretch.full);
    try std.testing.expectEqual(@as(u32, 37), h.state.edge.saved.stretch.carry);
    for (0..8) |variant| {
        var corrupt: [63]u8 = undefined;
        @memcpy(&corrupt, payload);
        switch (variant) {
            // Both legal board offsets and CPU1, before CPU0 finishes.
            0, 1, 2 => {
                corrupt[at.phase] = if (variant == 2) 1 else 2;
                @memset(corrupt[at.o..18], 0);
                if (variant == 1) corrupt[at.o] = 1;
            },
            3 => std.mem.writeInt(u64, corrupt[at.r..][0..8], std.math.maxInt(u64), .little),
            // CPU1 slots in a round CPU0 has not finished.
            4 => corrupt[at.cpu1_slots] = 1,
            5 => corrupt[at.o] = 36,
            6 => std.mem.writeInt(u64, corrupt[at.base0..][0..8], std.math.maxInt(u64), .little),
            else => corrupt[at.base0] +%= 1, // Scalar-valid, wrong staged CPU count.
        }
        try refused(&h, before.written(), .grid, &corrupt);
        std.debug.print("CHECK=G5 scalar variant={d} refused\n", .{variant});
    }
}

test "grid G6 cut metadata and version 10 are refused atomically" {
    var h = try openSingle();
    defer h.deinit();
    var before = try capture(&h);
    defer before.deinit();
    const payload = (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?.payload;
    try std.testing.expectEqual(@as(usize, 63), payload.len);
    var corrupt: [63]u8 = undefined;
    @memcpy(&corrupt, payload);
    corrupt[53] = 1; // A non-cut interval cannot retain a pending reload.
    try refused(&h, before.written(), .grid, &corrupt);
    @memcpy(&corrupt, payload);
    corrupt[at.cut] = 1;
    corrupt[52] = 2; // No third SysTick bank.
    try refused(&h, before.written(), .grid, &corrupt);
    corrupt[52] = 0;
    std.mem.writeInt(u32, corrupt[53..57], 1 << 24, .little);
    try refused(&h, before.written(), .grid, &corrupt);
    var old = try std.testing.allocator.dupe(u8, before.written());
    defer std.testing.allocator.free(old);
    std.mem.writeInt(u32, old[ra8.snapshot.file.magic.len..][0..4], 10, .little);
    try std.testing.expectError(error.BadVersion, h.state.files.readFrom(old));
    var after = try capture(&h);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
}

test "grid repair G5 legal partial CPU0, cut and board states load and recapture" {
    var h = try openSingle();
    defer h.deinit();
    h.state.edge.timebase.rearms = 1; // A cut names a clock that rearmed.
    var before = try capture(&h);
    defer before.deinit();
    const payload = (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?.payload;
    try accepted(&h, before.written(), .grid, payload);
    var legal: [63]u8 = undefined;
    @memcpy(&legal, payload);
    legal[at.cut] = 1;
    try accepted(&h, before.written(), .grid, &legal);
    try std.testing.expect(h.state.edge.saved.cut);
    legal[at.phase] = 2;
    @memset(legal[at.o..18], 0);
    try accepted(&h, before.written(), .grid, &legal);
    try std.testing.expectEqual(ra8.chip.core.scheduler.position.Phase.board, h.state.edge.saved.at.phase);
    try std.testing.expectEqual(@as(u32, 37), h.state.edge.saved.stretch.carry);
    std.debug.print("CHECK=G5 legal partial, cut and cut-board accepted\n", .{});
}

test "grid repair G5 closed turn cannot replace a genuine partial CPU1 turn" {
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf", .history_frames = 2 });
    defer h.deinit();
    var second: Cpu1 = .{};
    try second.open(std.testing.allocator, std.testing.io, &h, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(std.testing.allocator);
    h.state.edge.idle_skip = false;
    h.state.edge.timebase.per_chunk = 64;
    h.session().live.boundary.?.chunk = 64;
    const ended = try h.session().live.runToCount(1, 1);
    try std.testing.expect(ended == .stop and ended.stop == .stepped);
    try std.testing.expect(second.pair.turn_state.open);
    try std.testing.expectEqual(@as(u32, 1), h.state.edge.saved.lengths[1]);
    var before = try capture(&h);
    defer before.deinit();
    const kept = second.pair.turn_state;
    try turnRefusals(&h, &second, before.written());
    const grid = (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?.payload;
    for (0..2) |variant| {
        var corrupt: [63]u8 = undefined;
        @memcpy(&corrupt, grid);
        // The open turn's phase moved to the board, then a cut claimed in CPU1's phase.
        if (variant == 0) {
            corrupt[at.phase] = 2;
            @memset(corrupt[at.o..18], 0);
        } else corrupt[at.cut] = 1;
        try refused(&h, before.written(), .grid, &corrupt);
        std.debug.print("CHECK=G5 dual grid variant={d} refused\n", .{variant});
    }
    // The genuine partial turn is a legal state: it loads and recaptures.
    try accepted(&h, before.written(), .grid, grid);
    try std.testing.expect(second.pair.turn_state.open);
    try std.testing.expectEqual(kept.slots, second.pair.turn_state.slots);
    std.debug.print("CHECK=G5 dual partial turn accepted\n", .{});
    try legalTurns(&h, &second, before.written());
}

fn legalTurns(h: *Harness, second: *Cpu1, before: []const u8) !void {
    // Rates /64, /4, /3, /1, 4/3, 2/1 and 64/1 are all latchable.
    const pair = second.pair;
    for ([_]u32{ 1, 16, 21, 64, 85, 128, 4096 }) |share| {
        var legal = pair;
        legal.turn_state.share = share;
        legal.turn_state.hz = 123;
        legal.cycle_remainder = ra8.chip.periph.clocks.timebase.default_hz - 1;
        var payload = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer payload.deinit();
        try ra8.session.board.state.saveSecond(&legal, &payload.writer);
        try accepted(h, before, .second, payload.written()[12..]);
        std.debug.print("CHECK=G5 legal latched share={d} lower rate and remainder accepted\n", .{share});
    }
    try h.state.files.readFrom(before);
    second.pair.closeTurn();
    h.state.edge.saved.at.phase = .board;
    h.state.edge.saved.at.o = 0;
    h.state.edge.saved.at.gap = .retired;
    var board = try capture(h);
    defer board.deinit();
    try h.state.files.readFrom(board.written());
    var echoed = try capture(h);
    defer echoed.deinit();
    try std.testing.expectEqualSlices(u8, board.written(), echoed.written());
    std.debug.print("CHECK=G5 constructed closed board uses actual closeTurn bookkeeping\n", .{});
    var grid: [63]u8 = undefined;
    @memcpy(&grid, (try ra8.snapshot.file.Reader.find(board.written(), .grid)).?.payload);
    // Construct an internally consistent pending turn from the produced
    // closed one. The public Session does not pause at this transition.
    grid[at.phase] = 1;
    std.mem.writeInt(u64, grid[35..43], second.pair.core.cpu.slots, .little);
    @memset(grid[at.cpu1_slots..51], 0);
    @memset(grid[at.o..18], 0);
    try accepted(h, board.written(), .grid, &grid);
    std.debug.print("CHECK=G5 constructed pending unopened CPU1 accepted\n", .{});
    try h.state.files.readFrom(before);
}

const ClosedCase = enum { dropped, last_ran };
test "grid repair G5 closed board dropped slot is atomic" {
    try closedBoard(.dropped);
}
test "grid repair G5 closed board unrepresentable last ran is atomic" {
    try closedBoard(.last_ran);
}

fn closedBoard(comptime variant: ClosedCase) !void {
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf", .history_frames = 2 });
    defer h.deinit();
    var second: Cpu1 = .{};
    try second.open(std.testing.allocator, std.testing.io, &h, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(std.testing.allocator);
    h.state.edge.idle_skip = false;
    h.state.edge.timebase.per_chunk = 64;
    h.session().live.boundary.?.chunk = 64;
    const ended = try h.session().live.runToCount(1, 1);
    try std.testing.expect(ended == .stop and ended.stop == .stepped);
    if (variant == .dropped) {
        var before = try capture(&h);
        defer before.deinit();
        var closed = second.pair;
        closed.turn_state = .{};
        var body = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer body.deinit();
        try ra8.session.board.state.saveSecond(&closed, &body.writer);
        var changed = try fixture.replacement(before.written(), .second, body.written()[12..]);
        defer changed.deinit();
        var grid: [63]u8 = undefined;
        @memcpy(&grid, (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?.payload);
        grid[at.phase] = 2;
        @memset(grid[at.o..18], 0);
        var bad = try fixture.replacement(changed.written(), .grid, &grid);
        defer bad.deinit();
        try refusedFile(&h, before.written(), bad.written());
        std.debug.print("CHECK=G5 closed board dropped slot refused and byte-identical\n", .{});
        return;
    }
    second.pair.closeTurn();
    h.state.edge.saved.at.phase = .board;
    h.state.edge.saved.at.o = 0;
    h.state.edge.saved.at.gap = .retired;
    var baseline = try capture(&h);
    defer baseline.deinit();
    try std.testing.expectEqual(@as(u64, 1), second.pair.second.state.ran);
    try std.testing.expectEqual(@as(u64, 1), second.pair.last_ran);
    var closed = second.pair;
    closed.last_ran = @as(u64, 1) << 32;
    var large = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer large.deinit();
    try ra8.session.board.state.saveSecond(&closed, &large.writer);
    try refused(&h, baseline.written(), .second, large.written()[12..]);
    std.debug.print("CHECK=G5 closed board unrepresentable last_ran refused and byte-identical\n", .{});
}

fn turnRefusals(h: *Harness, second: *Cpu1, before: []const u8) !void {
    for (0..11) |variant| {
        var pair = second.pair;
        switch (variant) {
            0 => pair.turn_state = .{}, // The original G5 dropped-turn recipe.
            1 => pair.turn_state.slots = 0,
            2 => pair.turn_state.elapsed = pair.turn_state.share + 1,
            3 => pair.turn_state.elapsed = 0,
            4 => pair.turn_state.hz = 0,
            5 => pair.turn_state.hz = ra8.chip.periph.clocks.timebase.default_hz + 1,
            6 => pair.cycle_remainder = ra8.chip.periph.clocks.timebase.default_hz,
            7 => pair.turn_state.share = 0,
            8 => pair.turn_state.share = 65, // No divider yields 65 from this 64-slot interval.
            9 => pair.last_ran = 1,
            else => pair.second.state.ran = std.math.maxInt(u64),
        }
        var payload = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer payload.deinit();
        try ra8.session.board.state.saveSecond(&pair, &payload.writer);
        try refused(h, before, .second, payload.written()[12..]);
        std.debug.print("CHECK=G5 turn variant={d} refused and byte-identical\n", .{variant});
    }
}

test "grid repair G5 owed rate and sampled clock counts are checked jointly" {
    var h = try openSingle();
    defer h.deinit();
    var before = try capture(&h);
    defer before.deinit();
    const debt = (try ra8.snapshot.file.Reader.find(before.written(), .stretch)).?.payload;
    for (0..5) |variant| {
        var corrupt: [21]u8 = undefined;
        @memcpy(&corrupt, debt);
        switch (variant) {
            0 => corrupt[0] = 36,
            1 => corrupt[4] = 1,
            2 => corrupt[13] = 1,
            3 => {
                corrupt[12] = 1;
                corrupt[13] = 1;
            },
            else => corrupt[12] = 2,
        }
        try refused(&h, before.written(), .stretch, &corrupt);
        std.debug.print("CHECK=G5 debt variant={d} refused and byte-identical\n", .{variant});
    }
    const units = (try ra8.snapshot.file.Reader.find(before.written(), .debug_units)).?.payload;
    var cursor: ra8.snapshot.fields.Cursor = .{ .bytes = units };
    const count = try ra8.snapshot.fields.read(u8, &cursor);
    try std.testing.expectEqual(@as(u8, 1), count);
    var unit = try ra8.snapshot.fields.read(ra8.session.board.state.Units, &cursor);
    try std.testing.expect(cursor.done());
    unit.count.slots = h.primaryCpu().slots + 1;
    var corrupt = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer corrupt.deinit();
    try ra8.snapshot.fields.write(&corrupt.writer, count);
    try ra8.snapshot.fields.write(&corrupt.writer, unit);
    try refused(&h, before.written(), .debug_units, corrupt.written());
    std.debug.print("CHECK=G5 sampled clock ahead of CPU refused and byte-identical\n", .{});
}

test "grid repair G5 missing duplicate and trailing grid payloads preserve the run" {
    var h = try openSingle();
    defer h.deinit();
    var before = try capture(&h);
    defer before.deinit();
    for ([_]usize{ 0, 2 }) |copies| {
        var bad = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer bad.deinit();
        try ra8.snapshot.file.writeHeader(&bad.writer);
        var reader = try ra8.snapshot.file.Reader.open(before.written());
        while (try reader.next()) |section| for (0..if (section.kind == .grid) copies else 1) |_| {
            try ra8.snapshot.file.writeSectionHeader(&bad.writer, section.kind, section.payload.len);
            try bad.writer.writeAll(section.payload);
        };
        if (copies == 0) {
            try std.testing.expectError(error.Missing, h.state.files.readFrom(bad.written()));
        } else try std.testing.expectError(error.DuplicateSection, h.state.files.readFrom(bad.written()));
        var after = try capture(&h);
        defer after.deinit();
        try std.testing.expectEqualSlices(u8, before.written(), after.written());
        std.debug.print("CHECK=G5 grid copies={d} refused and byte-identical\n", .{copies});
    }
    const grid = (try ra8.snapshot.file.Reader.find(before.written(), .grid)).?.payload;
    var trailing: [64]u8 = @splat(0);
    @memcpy(trailing[0..63], grid);
    try refused(&h, before.written(), .grid, &trailing);
}
