//! Covers src/interfaces/gui/ui/memory_pane.zig (RA8EMU-746): a row's
//! columns line up, the pane rasterises to a pinned golden frame,
//! unreadable bytes draw only muted "??" and '?', and a pane too narrow
//! draws nothing and rows stop at what was captured.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const paint_backend = ra8.render.paint_backend;
const pane = gui_app.memory_pane;

const Rect = draw_list.Rect;
/// Exactly one row wide and four rows deep.
const area = Rect{ .x = 0, .y = 0, .w = pane.min_w, .h = 2 * pane.pad + 4 * pane.row_h };

/// Four rows of mixed printable and unprintable bytes; the last row's top
/// half cannot be read.
fn sample() pane.Snapshot {
    var snapshot: pane.Snapshot = .{ .base = 0x2000_0100, .count = 4 };
    for (0..4 * pane.per_row) |index| {
        snapshot.bytes[index] = @intCast((index * 7 + 0x20) & 0xFF);
        snapshot.readable[index] = index < 3 * pane.per_row + 8;
    }
    return snapshot;
}

const Scene = struct {
    frame: raster.Framebuffer,
    theme: *const gui_app.colors.Theme = dark,

    fn init() !Scene {
        const w: u32 = @intCast(area.w);
        const h: u32 = @intCast(area.h);
        return .{ .frame = try raster.Framebuffer.init(std.testing.allocator, w, h) };
    }

    fn deinit(self: *Scene) void {
        self.frame.deinit(std.testing.allocator);
    }

    /// Paint the pane straight through the shared table onto the frame.
    fn render(self: *Scene, snapshot: *const pane.Snapshot) !void {
        var backend = paint_backend.Backend.init(&self.frame);
        try pane.draw(&backend.paint(), self.theme, area, snapshot);
    }

    fn digest(self: *const Scene) u64 {
        const hash = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
        return hash;
    }

    /// Pixels holding `color`, exactly.
    fn pixelsOf(self: *const Scene, color: draw_list.Color) usize {
        var count: usize = 0;
        for (self.frame.pixels) |pixel| {
            if (std.meta.eql(pixel, color)) count += 1;
        }
        return count;
    }

    /// Pixels that differ from the frame's untouched zero state.
    fn painted(self: *const Scene) usize {
        var count: usize = 0;
        for (self.frame.pixels) |pixel| {
            if (!std.meta.eql(pixel, std.mem.zeroes(draw_list.Color))) count += 1;
        }
        return count;
    }

    /// Pixels at or below `y` that differ from `background`: nothing but
    /// the pane's own fill should reach there.
    fn paintedBelow(self: *const Scene, y: u32, background: draw_list.Color) usize {
        var count: usize = 0;
        for (self.frame.pixels, 0..) |pixel, index| {
            const py: u32 = @intCast(index / self.frame.width);
            if (py >= y and !std.meta.eql(pixel, background)) count += 1;
        }
        return count;
    }
};

test "a row is an address, sixteen hex bytes with a gap after the eighth, then ASCII" {
    try std.testing.expectEqual(@as(usize, 76), pane.row_len);
    try std.testing.expectEqual(pane.hex_at + 21, pane.hexColumn(7));
    try std.testing.expectEqual(pane.hex_at + 25, pane.hexColumn(8));
    try std.testing.expectEqual(pane.ascii_at, pane.hexColumn(15) + 4);
    try std.testing.expectEqual(@as(usize, 4), pane.rows(area));
    try std.testing.expectEqual(pane.pad + 2 + 3 * pane.row_h, pane.rowOrigin(area, 3).y);
}

test "the pane rasterises to the pinned golden frame" {
    var scene = try Scene.init();
    defer scene.deinit();
    const snapshot = sample();
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(u64, 6970880632380760691), scene.digest());
}

test "in the light palette the pane rasterises to its own pinned golden frame" {
    var scene = try Scene.init();
    defer scene.deinit();
    scene.theme = light;
    const snapshot = sample();
    try scene.render(&snapshot);
    try std.testing.expectEqual(@as(u64, 7983428817772575866), scene.digest());
}

test "unreadable bytes draw only muted question marks" {
    var scene = try Scene.init();
    defer scene.deinit();
    var snapshot: pane.Snapshot = .{ .base = 0, .count = 1 };
    @memset(snapshot.bytes[0..pane.per_row], 'A');
    @memset(snapshot.readable[0..12], true);
    try scene.render(&snapshot);
    try std.testing.expect(scene.pixelsOf(dark.ink) > 0);
    try std.testing.expect(scene.pixelsOf(dark.muted) > 0);
}

test "a pane too narrow draws nothing, and rows stop at what was captured" {
    var scene = try Scene.init();
    defer scene.deinit();
    var snapshot: pane.Snapshot = .{ .base = 0, .count = 2 };
    @memset(snapshot.bytes[0 .. 2 * pane.per_row], 'A');
    @memset(snapshot.readable[0 .. 2 * pane.per_row], true);
    var backend = paint_backend.Backend.init(&scene.frame);
    try pane.draw(&backend.paint(), dark, .{ .x = 0, .y = 0, .w = pane.min_w - 1, .h = area.h }, &snapshot);
    try std.testing.expectEqual(@as(usize, 0), scene.painted());
    try scene.render(&snapshot);
    try std.testing.expect(scene.painted() > 0);
    try std.testing.expectEqual(@as(usize, 0), scene.paintedBelow(@intCast(pane.rowOrigin(area, 2).y), dark.background));
}
