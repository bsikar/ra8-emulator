//! Covers src/interfaces/cli/report/json_timing.zig and json_pends.zig:
//! the `timing` object of `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");

const json_run = ra8.board.report.json_run;
const json_timing = json_run.json_timing;
const Value = std.json.Value;
const Fixture = @import("json_board.zig").Fixture;

fn render(board: *ra8.board.Board, timing: ?*const json_timing.Timing, buf: *std.ArrayList(u8)) !std.json.Parsed(Value) {
    try json_run.document(buf.writer(), board, .{ .engine = "unicorn", .elapsed = 1, .timing = timing });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.items, .{});
}

fn quiet() json_timing.Timing {
    return .{
        .timebase = .{},
        .seam = .{},
        .interrupts = .{},
        .release = .{},
        .pending = .{},
        .pacing = .{},
        .masking = .{},
    };
}

test "a run with no timing hooks writes null" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, null, &buf);
    defer doc.deinit();
    try std.testing.expect(doc.value.object.get("timing").? == .null);
}

test "a quiet run writes every key with null first addresses" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const of = quiet();
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &of, &buf);
    defer doc.deinit();
    const timing = doc.value.object.get("timing").?.object;
    for ([_][]const u8{ "elapsed", "dwt_cycles", "systick_periods", "idle", "interrupts", "mask", "pends" }) |key| {
        try std.testing.expect(timing.get(key) != null);
    }
    const interrupts = timing.get("interrupts").?.object;
    try std.testing.expect(interrupts.get("first_waiting").? == .null);
    try std.testing.expect(interrupts.get("passed").?.object.get("first_loser").? == .null);
    const pends = timing.get("pends").?.object;
    try std.testing.expect(pends.get("ledger").?.object.get("balanced").?.bool);
    try std.testing.expect(pends.get("cleared").?.object.get("first_at").? == .null);
    try std.testing.expect(pends.get("reopened").?.object.get("first_from").? == .null);
}

test "counters and the pend ledger carry the run's numbers" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var of = quiet();
    of.timebase.elapsed = 2000;
    of.timebase.cycles = 1500;
    of.timebase.ticks = 7;
    of.interrupts.taken = 6;
    of.pending.cuts = 3;
    of.pending.swallowed = 2;
    of.pending.reentered = 1;
    of.pending.reentered_at = 0x1234;
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &of, &buf);
    defer doc.deinit();
    const timing = doc.value.object.get("timing").?.object;
    try std.testing.expectEqual(@as(i64, 2000), timing.get("elapsed").?.integer);
    try std.testing.expectEqual(@as(i64, 1500), timing.get("dwt_cycles").?.integer);
    try std.testing.expectEqual(@as(i64, 7), timing.get("systick_periods").?.integer);
    try std.testing.expectEqual(@as(i64, 6), timing.get("interrupts").?.object.get("taken").?.integer);
    const pends = timing.get("pends").?.object;
    const ledger = pends.get("ledger").?.object;
    try std.testing.expectEqual(@as(i64, 3), ledger.get("raised").?.integer);
    try std.testing.expectEqual(@as(i64, 5), ledger.get("asks").?.integer);
    try std.testing.expectEqual(@as(i64, 3), ledger.get("outstanding").?.integer);
    try std.testing.expect(!ledger.get("balanced").?.bool);
    try std.testing.expectEqual(@as(i64, 0x1234), pends.get("reentered").?.object.get("first_at").?.integer);
}
