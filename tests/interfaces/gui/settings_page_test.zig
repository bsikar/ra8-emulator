//! Host tests for the shell's settings page (RA8EMU-963): the saved theme
//! and display choices' load, save and fallbacks, and the page's open,
//! choice press, outside press and Escape.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;

const settings_page = gui_app.shell.settings_page;
const shell_theme = gui_app.shell.theme;
const colors = gui_app.colors;
const Display = gui_app.display_settings.Display;

/// The middle of choice `index` in row `row` of the panel in an 800x600 window.
fn middle(row: settings_page.Row, index: usize) struct { x: i32, y: i32 } {
    const cell = settings_page.choiceArea(settings_page.panelOf(800, 600), @backingInt(row), index);
    return .{ .x = cell.x + @divTrunc(cell.w, 2), .y = cell.y + @divTrunc(cell.h, 2) };
}

/// The fresh per-user directory's path, in `buf`.
fn tmpPath(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});
}

test "the store round-trips a choice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const store = settings_page.Store{ .io = std.testing.io, .allocator = std.testing.allocator, .dir = try tmpPath(&tmp, &path_buf) };
    try std.testing.expectEqual(colors.Choice.system, store.load());
    store.save(.light);
    try std.testing.expectEqual(colors.Choice.light, store.load());
    store.save(.dark);
    try std.testing.expectEqual(colors.Choice.dark, store.load());
    store.save(.system);
    try std.testing.expectEqual(colors.Choice.system, store.load());
}

test "a missing or unreadable save reads as System" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    var store = settings_page.Store{ .io = std.testing.io, .allocator = gpa, .dir = try tmpPath(&tmp, &path_buf) };
    try std.testing.expectEqual(colors.Choice.system, store.load());
    // A store without a directory keeps this run's choice only.
    store.dir = null;
    try std.testing.expectEqual(colors.Choice.system, store.load());
    store.save(.light);
    try std.testing.expectEqual(colors.Choice.system, store.load());
}

test "a corrupt save reads as System, not a crash" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    var store = settings_page.Store{ .io = std.testing.io, .allocator = gpa, .dir = try tmpPath(&tmp, &path_buf) };
    store.save(.dark);
    var buf: [1024]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ store.dir.?, settings_page.file_name });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = "banana" });
    try std.testing.expectEqual(colors.Choice.system, store.load());
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = "LIGHT\n" });
    try std.testing.expectEqual(colors.Choice.system, store.load());
}

test "a press on a theme chooses it, saves it and leaves the page up" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const store = settings_page.Store{ .io = std.testing.io, .allocator = gpa, .dir = try tmpPath(&tmp, &path_buf) };
    var themes = shell_theme.Themes{};
    var page = settings_page.Page{ .store = &store };
    page.ask();
    try std.testing.expect(page.open);
    const light = middle(.theme, 1);
    try std.testing.expect(page.press(&themes, 800, 600, light.x, light.y));
    try std.testing.expect(page.open);
    try std.testing.expectEqual(colors.Choice.light, themes.choice());
    try std.testing.expect(themes.active == &colors.palettes.light);
    try std.testing.expectEqual(colors.Choice.light, store.load());
    try std.testing.expectEqual(@as(usize, 1), page.chosen(&themes, .theme));
    // System again: the shell follows the OS.
    const system = middle(.theme, 0);
    _ = page.press(&themes, 800, 600, system.x, system.y);
    try std.testing.expectEqual(colors.Choice.system, themes.choice());
    try std.testing.expect(themes.follow_os);
    // A theme pick leaves the display choices alone, saved or not.
    try std.testing.expectEqual(Display{}, page.display);
    try std.testing.expectEqual(Display{}, store.loadDisplay());
}

test "the display rows set vsync, the frame rate limit and the counter, and save them" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const store = settings_page.Store{ .io = std.testing.io, .allocator = gpa, .dir = try tmpPath(&tmp, &path_buf) };
    var themes = shell_theme.Themes{};
    var page = settings_page.Page{ .store = &store };
    page.ask();
    const off = middle(.vsync, 1);
    try std.testing.expect(page.press(&themes, 800, 600, off.x, off.y));
    try std.testing.expect(!page.display.vsync);
    const limit = middle(.limit, 3);
    try std.testing.expect(page.press(&themes, 800, 600, limit.x, limit.y));
    try std.testing.expectEqual(gui_app.display_settings.Limit.fps144, page.display.limit);
    const counter = middle(.counter, 0);
    try std.testing.expect(page.press(&themes, 800, 600, counter.x, counter.y));
    try std.testing.expect(page.display.counter);
    try std.testing.expect(page.open);
    try std.testing.expectEqual(@as(usize, 1), page.chosen(&themes, .vsync));
    try std.testing.expectEqual(@as(usize, 3), page.chosen(&themes, .limit));
    try std.testing.expectEqual(@as(usize, 0), page.chosen(&themes, .counter));
    const live = middle(.registers, 3);
    try std.testing.expect(page.press(&themes, 800, 600, live.x, live.y));
    try std.testing.expectEqual(gui_app.display_settings.Live.hz30, page.display.registers);
    try std.testing.expectEqual(@as(usize, 3), page.chosen(&themes, .registers));
    try std.testing.expectEqual(Display{ .vsync = false, .limit = .fps144, .counter = true, .registers = .hz30 }, store.loadDisplay());
    // The theme was never touched.
    try std.testing.expectEqual(colors.Choice.dark, themes.choice());
}

test "a missing or corrupt display save reads as the defaults" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    var store = settings_page.Store{ .io = std.testing.io, .allocator = gpa, .dir = try tmpPath(&tmp, &path_buf) };
    try std.testing.expectEqual(Display{}, store.loadDisplay());
    var buf: [1024]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ store.dir.?, settings_page.display_file_name });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path, .data = "banana" });
    try std.testing.expectEqual(Display{}, store.loadDisplay());
    store.dir = null;
    store.saveDisplay(.{ .counter = true });
    try std.testing.expectEqual(Display{}, store.loadDisplay());
}

test "Escape closes the page and a press outside closes it too" {
    var themes = shell_theme.Themes{};
    var page = settings_page.Page{};
    page.ask();
    try std.testing.expect(page.key(.{ .key = .{ .code = 0x1B, .down = true } }));
    try std.testing.expect(!page.open);
    try std.testing.expectEqual(colors.Choice.dark, themes.choice());
    // A closed page takes nothing.
    try std.testing.expect(!page.key(.{ .key = .{ .code = 0x1B, .down = true } }));
    try std.testing.expect(!page.press(&themes, 800, 600, 400, 300));
    // A press outside the open panel closes it.
    page.ask();
    try std.testing.expect(page.press(&themes, 800, 600, 2, 2));
    try std.testing.expect(!page.open);
    // A press on the panel's padding or a setting's name is kept.
    const panel = settings_page.panelOf(800, 600);
    page.ask();
    try std.testing.expect(page.press(&themes, 800, 600, panel.x + 2, panel.y + 2));
    const name = settings_page.rowArea(panel, 2);
    try std.testing.expect(page.press(&themes, 800, 600, name.x + 2, name.y + 4));
    try std.testing.expect(page.open);
    try std.testing.expectEqual(Display{}, page.display);
    page.open = false;
}

test "the page draws over the shell" {
    const gpa = std.testing.allocator;
    var themes = shell_theme.Themes{};
    var page = settings_page.Page{};
    page.ask();
    var list = draw_list.DrawList.init(gpa, 800, 600);
    defer list.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();
    try page.draw(&paint, &themes, colors.of(.dark), 800, 600);
    try page.draw(&paint, &themes, colors.of(.light), 800, 600);
}
