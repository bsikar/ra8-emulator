//! Host tests for time bar drawing and rasterization (RA8EMU-807):
//! pinned CPU-backend golden frames in dark and light themes, an editing field,
//! RTC date wide frames, short and narrow bars keeping whole clock segments,
//! vertical glyph alignment, and empty bar drawing.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const Theme = @import("gui_app").colors.Theme;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const status_bar = gui_app.status.bar;
const speed_field = gui_app.speed_field;
const seek_field = gui_app.seek_field;
const time_readout = gui_app.time.readout;
const bar = gui_app.time_bar;
const capture = gui_app.time.bar_capture;
const Run = gui_app.shell.run.Run;
const Status = status_bar.Status;
const Rect = draw_list.Rect;

const Models = struct {
    status: Status = .{},
    field: speed_field.Field = .{},
    seek: seek_field.Field = .{},
    readout: time_readout.Readout = .{},
    texts: capture.Texts = .{},
    run: Run = .{},

    fn sample() Models {
        var models: Models = .{};
        models.status.run = .{ .halted = .{ .address = 0x0800_0100, .reason = .stepped } };
        models.field.applied = 250;
        models.readout.virtual_ns = 83_456_000_000;
        models.readout.achieved_milli = 120;
        return models;
    }

    fn view(self: *Models, editing: bool) bar.View {
        return capture.view(&self.texts, &self.status, &self.field, &self.seek, &self.readout, &self.run, editing, false, false);
    }
};

const Scene = struct {
    list: draw_list.DrawList,
    frame: raster.Framebuffer,
    /// The palette the scene paints with (RA8EMU-961).
    theme: *const Theme = dark,

    fn init(width: u32, height: u32) !Scene {
        return .{ .list = draw_list.DrawList.init(std.testing.allocator, width, height), .frame = try raster.Framebuffer.init(std.testing.allocator, width, height) };
    }

    fn deinit(self: *Scene) void {
        self.list.deinit();
        self.frame.deinit(std.testing.allocator);
    }

    fn render(self: *Scene, area: Rect, view: bar.View) !void {
        var target = ra8.render.widget_paint.Target{ .list = &self.list };
        const paint = target.paint();
        bar.draw(&paint, self.theme, area, view);
        raster.draw(&self.frame, &self.list, font.atlas);
    }

    fn digest(self: *const Scene) u64 {
        const hash = std.hash.Fnv1a_64.hash(std.mem.sliceAsBytes(self.frame.pixels));
        return hash;
    }
};

// Whole segments, muted disabled controls and the requested Speed label.
test "the bar rasterises to the pinned golden frame" {
    var scene = try Scene.init(480, bar.height);
    defer scene.deinit();
    var models = Models.sample();
    try scene.render(.{ .x = 0, .y = 0, .w = 480, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(u64, 15308113852488572895), scene.digest());
}

test "the bar rasterises to the pinned golden frame in the light theme" {
    var scene = try Scene.init(480, bar.height);
    defer scene.deinit();
    scene.theme = light;
    var models = Models.sample();
    try scene.render(.{ .x = 0, .y = 0, .w = 480, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(u64, 5938799604048781550), scene.digest());
}

test "the editing field rasterises to its pinned golden frame" {
    var scene = try Scene.init(480, bar.height);
    defer scene.deinit();
    var models = Models.sample();
    models.status.run = .running;
    models.run.lit = true;
    models.field.typed("5");
    try scene.render(.{ .x = 0, .y = 0, .w = 480, .h = bar.height }, models.view(true));
    try std.testing.expectEqual(@as(u64, 5393682526625849969), scene.digest());
}

test "the bar with an RTC date rasterises to its pinned golden frame, wide enough for the whole line" {
    var scene = try Scene.init(800, bar.height);
    defer scene.deinit();
    var models = Models.sample();
    models.readout.date = .{ .year = 2026, .month = 10, .day = 8, .hour = 9, .minute = 47, .second = 5 };
    try scene.render(.{ .x = 0, .y = 0, .w = 800, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(u64, 17001970104089201796), scene.digest());
}

test "a short bar hides incomplete controls and keeps the whole clock line" {
    const cell: i32 = @intCast(font.cell_w);
    var scene = try Scene.init(480, 20);
    defer scene.deinit();
    var models = Models.sample();
    models.readout.date = .{ .year = 2026, .month = 10, .day = 8, .hour = 9, .minute = 47, .second = 5 };
    const view = models.view(false);
    const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = 20 };
    try scene.render(area, view);
    const clock = bar.Layout.of(area).clock;
    const cells: usize = @intCast(@divFloor(clock.w - 2 * bar.pad, cell));
    const elapsed = view.clock;
    const date = view.clock_date orelse return error.NoDate;
    // No control fits vertically, leaving the clock its complete line.
    try std.testing.expect(bar.Layout.of(area).run.empty());
    const speed = view.clock_speed.?;
    const shown_len = date.len + 3 + elapsed.len + 3 + speed.len;
    try std.testing.expect(shown_len <= cells);
    try std.testing.expectEqualStrings(date, "2026-10-08 09:47:05");
    const left = clock.x + bar.pad;
    var x = left + @as(i32, @intCast(shown_len)) * cell;
    while (x < area.w) : (x += 1) {
        var y: i32 = 0;
        while (y < area.h) : (y += 1) try std.testing.expect(!std.meta.eql(scene.frame.at(@intCast(x), @intCast(y)), dark.muted));
    }
    try std.testing.expectEqual(@as(u64, 574503664485954541), scene.digest());
}

/// The first row inside `area` with a pixel of `color`, or null.
fn firstRow(scene: *const Scene, area: Rect, color: draw_list.Color) ?i32 {
    var y = area.y;
    while (y < area.y + area.h) : (y += 1) {
        var x = area.x;
        while (x < area.x + area.w) : (x += 1) {
            if (std.meta.eql(scene.frame.at(@intCast(x), @intCast(y)), color)) return y;
        }
    }
    return null;
}

test "the clock readout stands on the row the button labels and the speed field stand on" {
    for ([_]*const Theme{ dark, light }) |theme| {
        var scene = try Scene.init(480, bar.height);
        defer scene.deinit();
        scene.theme = theme;
        var models = Models.sample();
        const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = bar.height };
        try scene.render(area, models.view(false));
        const layout = bar.Layout.of(area);
        // "Step", the field's "0.25x" and the clock's "T+" all start with a full-height glyph.
        const want = layout.step.y + @divFloor(layout.step.h - @as(i32, font.glyph_h), 2);
        const label_y = firstRow(&scene, layout.step, theme.ink).?;
        try std.testing.expect(label_y >= want and label_y < want + @as(i32, font.glyph_h));
        try std.testing.expectEqual(label_y, firstRow(&scene, layout.field, theme.ink).?);
        try std.testing.expectEqual(label_y, firstRow(&scene, layout.clock, theme.muted).?);
    }
}

test "a narrow bar's clock keeps whole segments: the speed, then the date, go before the elapsed is cut" {
    const cell: i32 = @intCast(font.cell_w);
    for ([_]u32{ 300, 437, 455, 640 }) |width| {
        var scene = try Scene.init(width, bar.height);
        defer scene.deinit();
        var models = Models.sample();
        models.readout.date = .{ .year = 2026, .month = 10, .day = 8, .hour = 9, .minute = 47, .second = 5 };
        const view = models.view(false);
        const area: Rect = .{ .x = 0, .y = 0, .w = @intCast(width), .h = bar.height };
        try scene.render(area, view);
        const clock_rect = bar.Layout.of(area).clock;
        const cells: usize = @intCast(@divFloor(clock_rect.w - 2 * bar.pad, cell));
        const sep: usize = 3;
        const elapsed = view.clock;
        const date = view.clock_date orelse return error.NoDate;
        const speed = view.clock_speed orelse return error.NoSpeed;
        // The policy in characters decides the line the row should show.
        var buf: [96]u8 = undefined;
        var expected: []const u8 = undefined;
        if (elapsed.len > cells) {
            expected = elapsed[0..cells];
        } else if (date.len + sep + elapsed.len + sep + speed.len <= cells) {
            expected = try std.fmt.bufPrint(&buf, "{s} | {s} | {s}", .{ date, elapsed, speed });
        } else if (date.len + sep + elapsed.len <= cells) {
            expected = try std.fmt.bufPrint(&buf, "{s} | {s}", .{ date, elapsed });
        } else expected = elapsed;
        try std.testing.expect(expected.len <= cells);
        const left = clock_rect.x + bar.pad;
        const top = clock_rect.y + @divFloor(clock_rect.h - @as(i32, font.glyph_h), 2);
        // Nothing of any dropped segment paints past the line's last whole cell.
        var x = left + @as(i32, @intCast(expected.len)) * cell;
        while (x < area.w) : (x += 1) {
            var y: i32 = 0;
            while (y < area.h) : (y += 1) try std.testing.expect(!std.meta.eql(scene.frame.at(@intCast(x), @intCast(y)), dark.muted));
        }
        // Every cell that is shown is the whole glyph of the expected line.
        var index: usize = 0;
        while (index < expected.len) : (index += 1) {
            const origin = font.cell(expected[index]);
            for (0..font.cell_h) |row| for (0..font.cell_w) |column| {
                const inked = expected[index] != ' ' and font.atlas.coverage[(origin.y + row) * font.atlas.width + origin.x + column] != 0;
                const at = scene.frame.at(@intCast(left + @as(i32, @intCast(index)) * cell + @as(i32, @intCast(column))), @intCast(top + @as(i32, @intCast(row))));
                try std.testing.expectEqual(inked, std.meta.eql(at, dark.muted));
            };
        }
    }
}

test "a bar too narrow for its controls paints nothing past its area" {
    var scene = try Scene.init(200, 40);
    defer scene.deinit();
    var models = Models.sample();
    const area: Rect = .{ .x = 30, .y = 10, .w = 70, .h = bar.height };
    try scene.render(area, models.view(true));
    const clear: draw_list.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    var painted: usize = 0;
    var y: u32 = 0;
    while (y < scene.frame.height) : (y += 1) {
        var x: u32 = 0;
        while (x < scene.frame.width) : (x += 1) {
            if (area.contains(@intCast(x), @intCast(y))) {
                painted += 1;
            } else try std.testing.expectEqual(clear, scene.frame.at(x, y));
        }
    }
    try std.testing.expect(painted > 0);
    try std.testing.expect(bar.Layout.of(area).field.empty());
}

test "an empty bar draws nothing" {
    var list = draw_list.DrawList.init(std.testing.allocator, 8, 8);
    defer list.deinit();
    var models = Models.sample();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    bar.draw(&paint, dark, .{ .x = 0, .y = 0, .w = 0, .h = bar.height }, models.view(false));
    try std.testing.expectEqual(@as(usize, 0), list.commands.items.len);
}
