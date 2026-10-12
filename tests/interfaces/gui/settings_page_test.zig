//! Host tests for the shell's settings page (RA8EMU-963): the saved theme
//! choice's load, save and fallbacks, and the page's open, row press,
//! outside press and Escape.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;

const settings_page = gui_app.shell.settings_page;
const shell_theme = gui_app.shell.theme;
const colors = gui_app.colors;

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

test "a row press chooses its theme, saves it and closes the page" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [64]u8 = undefined;
    const store = settings_page.Store{ .io = std.testing.io, .allocator = gpa, .dir = try tmpPath(&tmp, &path_buf) };
    var themes = shell_theme.Themes{};
    var page = settings_page.Page{ .store = &store };
    page.ask();
    try std.testing.expect(page.open);
    const panel = settings_page.panelOf(800, 600);
    const row = settings_page.rowArea(panel, 1);
    const took = page.press(&themes, 800, 600, row.x + @divTrunc(row.w, 2), row.y + @divTrunc(row.h, 2));
    try std.testing.expect(took);
    try std.testing.expect(!page.open);
    try std.testing.expectEqual(colors.Choice.light, themes.choice());
    try std.testing.expect(themes.active == &colors.palettes.light);
    try std.testing.expectEqual(colors.Choice.light, store.load());
    // System again: the shell follows the OS.
    page.ask();
    const first = settings_page.rowArea(panel, 0);
    _ = page.press(&themes, 800, 600, first.x + @divTrunc(first.w, 2), first.y + @divTrunc(first.h, 2));
    try std.testing.expectEqual(colors.Choice.system, themes.choice());
    try std.testing.expect(themes.follow_os);
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
    // A press on the panel's padding is kept.
    const panel = settings_page.panelOf(800, 600);
    page.ask();
    try std.testing.expect(page.press(&themes, 800, 600, panel.x + 2, panel.y + 2));
    try std.testing.expect(page.open);
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
