//! Host tests for the locals pane's paint (RA8EMU-805): a too-small pane
//! draws nothing, the full-size pane renders differently from a blank
//! frame, and a snapshot longer than the pane clips to the rows that fit.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const dark = &gui_app.colors.palettes.dark;
const pane = gui_app.locals_pane;

const allocator = std.testing.allocator;
const Rect = draw_list.Rect;

/// The snapshot the tests draw: four locals, one per where kind.
fn snapshot() pane.Snapshot {
    var snap: pane.Snapshot = .{};
    put(&snap, "ch", "char", 1, 1, -8, 0);
    put(&snap, "val", "u32", 4, 2, 4, 16);
    put(&snap, "reg", "u16", 2, 3, 7, 0);
    put(&snap, "flag", "bool", 1, 4, 0x02000100, 0);
    return snap;
}

fn put(snap: *pane.Snapshot, name: []const u8, type_name: []const u8, size: u64, kind: u8, a: i64, b: i64) void {
    const row = &snap.rows[snap.count];
    row.name_len = name.len;
    @memcpy(row.name_buf[0..name.len], name);
    row.type_len = type_name.len;
    @memcpy(row.type_buf[0..type_name.len], type_name);
    row.size = size;
    row.where_kind = kind;
    row.where_a = a;
    row.where_b = b;
    snap.count += 1;
}

/// A frame nothing drew, for the draws-nothing comparison.
fn blankDigest(w: i32, h: i32) !u64 {
    var frame = try raster.Framebuffer.init(allocator, @intCast(w), @intCast(h));
    defer frame.deinit(allocator);
    var list = draw_list.DrawList.init(allocator, @intCast(w), @intCast(h));
    defer list.deinit();
    raster.draw(&frame, &list, ra8.render.font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

fn digest(snap: *const pane.Snapshot, w: i32, h: i32) !u64 {
    const area = Rect{ .x = 0, .y = 0, .w = w, .h = h };
    var list = draw_list.DrawList.init(allocator, @intCast(w), @intCast(h));
    defer list.deinit();
    var frame = try raster.Framebuffer.init(allocator, @intCast(w), @intCast(h));
    defer frame.deinit(allocator);
    try pane.draw(&list, dark, area, snap);
    raster.draw(&frame, &list, ra8.render.font.atlas);
    return std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(frame.pixels));
}

test "a too-small pane draws nothing" {
    const area_w = pane.min_w - 1;
    const h = 200;
    var snap = snapshot();
    try std.testing.expectEqual(try blankDigest(area_w, h), try digest(&snap, area_w, h));
    const short_h = 2 * pane.pad; // rows(area) == 0
    var list = draw_list.DrawList.init(allocator, 300, 100);
    defer list.deinit();
    try pane.draw(&list, dark, Rect{ .x = 0, .y = 0, .w = 300, .h = short_h }, &snap);
}

test "the full-size pane renders the rows differently from a blank frame" {
    var snap = snapshot();
    const w = pane.min_w + 40;
    try std.testing.expect(try digest(&snap, w, 300) != try blankDigest(w, 300));
}

test "the default shell pane is wide enough to show locals" {
    var snap = snapshot();
    const w = 735;
    try std.testing.expect(try digest(&snap, w, 500) != try blankDigest(w, 500));
}

test "a snapshot longer than the pane clips to the rows that fit" {
    // A full 32-row snapshot against a pane that fits a third of it.
    const w = pane.min_w + 40;
    const h = 200;
    const fit = pane.rows(Rect{ .x = 0, .y = 0, .w = w, .h = h });
    try std.testing.expect(fit > 0 and fit < pane.max_rows);
    var long: pane.Snapshot = .{};
    var clipped: pane.Snapshot = .{};
    for (0..pane.max_rows) |row| {
        var name: [8]u8 = undefined;
        const label = std.fmt.bufPrint(&name, "v{d:0>7}", .{row}) catch unreachable;
        put(&long, label, "u32", 4, 3, 3, 0);
        if (row < fit) put(&clipped, label, "u32", 4, 3, 3, 0);
    }
    try std.testing.expectEqual(try digest(&long, w, h), try digest(&clipped, w, h));
}

test "an address where reads as the address, not a signed form" {
    var local: pane.Row = .{ .where_kind = 4, .where_a = 0x02000100 };
    var buf: [22]u8 = undefined;
    try std.testing.expectEqualStrings("@0x02000100", try pane.whereLabel(&buf, &local));
}
