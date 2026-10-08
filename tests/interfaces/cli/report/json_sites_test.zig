//! Covers src/interfaces/cli/report/json_sites.zig: the `sites` object of
//! `--report json`, parsed back with std.json.
const std = @import("std");
const ra8 = @import("ra8");

const json_run = ra8.board.report.json_run;
const json_sites = json_run.json_sites;
const Value = std.json.Value;
const Fixture = @import("json_board.zig").Fixture;

fn render(board: *ra8.board.Board, sites: ?*const json_sites.Sites, buf: *std.Io.Writer.Allocating) !std.json.Parsed(Value) {
    try json_run.document(&buf.writer, board, .{ .engine = "zig", .elapsed = 1, .sites = sites });
    return std.json.parseFromSlice(Value, std.testing.allocator, buf.written(), .{});
}

test "a run with no site hooks writes null" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, null, &buf);
    defer doc.deinit();
    try std.testing.expect(doc.value.object.get("sites").? == .null);
}

test "quiet tables are empty lists and absent tables are null" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    const of = json_sites.Sites{};
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &of, &buf);
    defer doc.deinit();
    const sites = doc.value.object.get("sites").?.object;
    for ([_][]const u8{ "pend_stores", "mask_give_ups" }) |key| {
        const table = sites.get(key).?.object;
        try std.testing.expectEqual(@as(usize, 0), table.get("sites").?.array.items.len);
        try std.testing.expectEqual(@as(i64, 0), table.get("overflowed").?.integer);
    }
    for ([_][]const u8{ "pc_hits", "taken_from", "taken_in" }) |key| {
        try std.testing.expect(sites.get(key).? == .null);
    }
}

test "stores rank by count and taken-from lists every kept site" {
    var fix: Fixture = undefined;
    try fix.open();
    defer fix.close();
    var of = json_sites.Sites{};
    of.pend.record(0x100);
    of.pend.record(0x200);
    of.pend.record(0x200);
    var taken: ra8.core.tally.Tally = .{};
    taken.record(0x300, 15);
    taken.record(0x300, 15);
    taken.record(0x400, 11);
    of.taken = &taken;
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    const doc = try render(&fix.board, &of, &buf);
    defer doc.deinit();
    const sites = doc.value.object.get("sites").?.object;
    const stores = sites.get("pend_stores").?.object.get("sites").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), stores.len);
    try std.testing.expectEqual(@as(i64, 0x200), stores[0].object.get("pc").?.integer);
    try std.testing.expectEqual(@as(i64, 2), stores[0].object.get("count").?.integer);
    try std.testing.expect(stores[0].object.get("symbol").? == .null);
    const from = sites.get("taken_from").?.object.get("sites").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), from.len);
    try std.testing.expectEqual(@as(i64, 15), from[0].object.get("exception").?.integer);
    try std.testing.expectEqual(@as(i64, 2), from[0].object.get("entries").?.integer);
}
