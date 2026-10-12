//! Host tests for the shell's menu actions (RA8EMU-957): a shortcut key
//! toggles a pane kind empty and takes it back, quit closes the shell, the
//! open command asks the OS's file picker from the key and the strip's
//! item, and a disabled item keeps its drop-down out.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const pane_layout = gui_app.pane_layout;
const shell_frame = gui_app.shell.frame;
const shell_loop = gui_app.shell.loop;
const shell_open = gui_app.shell.open;
const menu_actions = gui_app.shell.menu_actions;
const menu_bar = gui_app.menu_bar;
const Headless = gui_app.headless.Headless;

const width = 480;
const height = 320;

fn shell() !shell_loop.Shell {
    return shell_loop.Shell.init(std.testing.allocator, try pane_layout.twoCore(std.testing.allocator));
}

fn solved(s: *shell_loop.Shell) !pane_layout.Solved {
    return shell_frame.solve(&s.layout, std.testing.allocator, width, height);
}

fn boards(s: *const shell_loop.Shell) usize {
    var found: usize = 0;
    for (s.layout.nodes.items) |node| switch (node.body) {
        .leaf => |pane| {
            if (pane.kind == .board) found += 1;
        },
        else => {},
    };
    return found;
}

test "a shortcut key toggles the pane kind empty and takes it back" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    var placed = try solved(&s);
    defer placed.deinit(std.testing.allocator);
    menu_actions.observe(&s, width);
    try std.testing.expectEqual(@as(usize, 1), boards(&s));
    s.handle(.{ .key = .{ .code = '1', .down = true, .primary = true } }, &placed);
    try std.testing.expectEqual(@as(usize, 0), boards(&s));
    s.handle(.{ .key = .{ .code = '1', .down = true, .primary = true } }, &placed);
    try std.testing.expectEqual(@as(usize, 1), boards(&s));
}

test "the quit shortcut closes the shell" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    var placed = try solved(&s);
    defer placed.deinit(std.testing.allocator);
    s.handle(.{ .key = .{ .code = 'q', .down = true, .primary = true } }, &placed);
    try std.testing.expect(!s.open);
}

test "the open command asks the picker from the key and the strip" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    var placed = try solved(&s);
    defer placed.deinit(std.testing.allocator);
    var open: shell_open.Open = .{ .io = std.testing.io, .allocator = std.testing.allocator };
    s.files = &open;
    menu_actions.observe(&s, width);
    s.handle(.{ .key = .{ .code = 'o', .down = true, .primary = true } }, &placed);
    try std.testing.expect(open.asked);
    // The strip's own item fires the same ask.
    open.asked = false;
    const title = menu_bar.title(width, 0);
    s.handle(.{ .button = .{ .button = 1, .down = true, .x = title.x + @divTrunc(title.w, 2), .y = @divTrunc(title.h, 2) } }, &placed);
    try std.testing.expectEqual(@as(?usize, 0), s.menu.bar.open);
    const item = menu_bar.row(width, 0, 0, builtin.os.tag);
    s.handle(.{ .button = .{ .button = 1, .down = true, .x = item.x + @divTrunc(item.w, 2), .y = item.y + @divTrunc(item.h, 2) } }, &placed);
    try std.testing.expect(open.asked);
    try std.testing.expectEqual(@as(?usize, null), s.menu.bar.open);
}

test "a disabled item keeps its drop-down out" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    var placed = try solved(&s);
    defer placed.deinit(std.testing.allocator);
    menu_actions.observe(&s, width);
    const title = menu_bar.title(width, 1);
    s.handle(.{ .button = .{ .button = 1, .down = true, .x = title.x + @divTrunc(title.w, 2), .y = @divTrunc(title.h, 2) } }, &placed);
    try std.testing.expectEqual(@as(?usize, 1), s.menu.bar.open);
    // Run with no image loaded is disabled: the drop-down stays out.
    const item = menu_bar.row(width, 1, 0, builtin.os.tag);
    s.handle(.{ .button = .{ .button = 1, .down = true, .x = item.x + @divTrunc(item.w, 2), .y = item.y + @divTrunc(item.h, 2) } }, &placed);
    try std.testing.expectEqual(@as(?usize, 1), s.menu.bar.open);
}
