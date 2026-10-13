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
const menu = gui_app.menu;
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

fn click(s: *shell_loop.Shell, window: *Headless, placed: *const pane_layout.Solved, x: i32, y: i32) void {
    s.handle(window.platform(), .{ .button = .{ .button = 1, .down = true, .x = x, .y = y } }, placed);
    s.handle(window.platform(), .{ .button = .{ .button = 1, .down = false, .x = x, .y = y } }, placed);
}

fn viewItem(s: *shell_loop.Shell, window: *Headless, placed: *const pane_layout.Solved, at: usize) void {
    const title = menu_bar.title(&menu.bar, width, 2);
    click(s, window, placed, title.x + @divTrunc(title.w, 2), @divTrunc(title.h, 2));
    const item = menu_bar.row(&menu.bar, width, 2, at, s.menu.os);
    click(s, window, placed, item.x + 4, item.y + @divTrunc(item.h, 2));
}

test "View menu actions consume the press over a pane title and content" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = shell_loop.Shell.init(std.testing.allocator, try pane_layout.Layout.init(std.testing.allocator, .{ .kind = .board, .core = .cpu0 }));
    defer s.deinit();
    var placed = try solved(&s);
    defer placed.deinit(std.testing.allocator);
    menu_actions.observe(&s, window.platform(), width);

    viewItem(&s, &window, &placed, 0);
    try std.testing.expectEqual(pane_layout.Kind.empty, s.layout.pane(s.layout.root).?.kind);
    try std.testing.expectEqual(@as(?usize, null), s.menu.bar.open);
    try std.testing.expectEqual(@as(?pane_layout.Gutter, null), s.held);

    viewItem(&s, &window, &placed, 8);
    try std.testing.expectEqual(pane_layout.Kind.timeline, s.layout.pane(s.layout.root).?.kind);
    try std.testing.expectEqual(@as(?usize, null), s.menu.bar.open);

    // An outside press closes an open menu without changing the title below.
    const view = menu_bar.title(&menu.bar, width, 2);
    click(&s, &window, &placed, view.x + @divTrunc(view.w, 2), @divTrunc(view.h, 2));
    try std.testing.expectEqual(@as(?usize, 2), s.menu.bar.open);
    const pane_title = shell_frame.titleOf(placed.panes.items[0].area);
    const x = pane_title.x + 20;
    const y = pane_title.y + @divTrunc(pane_title.h, 2);
    click(&s, &window, &placed, x, y);
    try std.testing.expectEqual(@as(?usize, null), s.menu.bar.open);
    try std.testing.expectEqual(pane_layout.Kind.timeline, s.layout.pane(s.layout.root).?.kind);

    // Once the menu is closed, the same title click still reaches the pane.
    click(&s, &window, &placed, x, y);
    try std.testing.expectEqual(pane_layout.Kind.source, s.layout.pane(s.layout.root).?.kind);
}

test "a shortcut key toggles the pane kind empty and takes it back" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    var placed = try solved(&s);
    defer placed.deinit(std.testing.allocator);
    menu_actions.observe(&s, window.platform(), width);
    try std.testing.expectEqual(@as(usize, 1), boards(&s));
    s.handle(window.platform(), .{ .key = .{ .code = '1', .down = true, .primary = true } }, &placed);
    try std.testing.expectEqual(@as(usize, 0), boards(&s));
    s.handle(window.platform(), .{ .key = .{ .code = '1', .down = true, .primary = true } }, &placed);
    try std.testing.expectEqual(@as(usize, 1), boards(&s));
}

test "the quit shortcut closes the shell" {
    var window = Headless.init(std.testing.allocator, width, height);
    defer window.deinit();
    var s = try shell();
    defer s.deinit();
    var placed = try solved(&s);
    defer placed.deinit(std.testing.allocator);
    s.handle(window.platform(), .{ .key = .{ .code = 'q', .down = true, .primary = true } }, &placed);
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
    menu_actions.observe(&s, window.platform(), width);
    s.handle(window.platform(), .{ .key = .{ .code = 'o', .down = true, .primary = true } }, &placed);
    try std.testing.expect(open.asked);
    // The strip's own item fires the same ask.
    open.asked = false;
    const title = menu_bar.title(&menu.bar, width, 0);
    s.handle(window.platform(), .{ .button = .{ .button = 1, .down = true, .x = title.x + @divTrunc(title.w, 2), .y = @divTrunc(title.h, 2) } }, &placed);
    try std.testing.expectEqual(@as(?usize, 0), s.menu.bar.open);
    const item = menu_bar.row(&menu.bar, width, 0, 0, builtin.os.tag);
    s.handle(window.platform(), .{ .button = .{ .button = 1, .down = true, .x = item.x + @divTrunc(item.w, 2), .y = item.y + @divTrunc(item.h, 2) } }, &placed);
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
    menu_actions.observe(&s, window.platform(), width);
    const title = menu_bar.title(&menu.bar, width, 1);
    s.handle(window.platform(), .{ .button = .{ .button = 1, .down = true, .x = title.x + @divTrunc(title.w, 2), .y = @divTrunc(title.h, 2) } }, &placed);
    try std.testing.expectEqual(@as(?usize, 1), s.menu.bar.open);
    // Run with no image loaded is disabled: the drop-down stays out.
    const item = menu_bar.row(&menu.bar, width, 1, 0, builtin.os.tag);
    s.handle(window.platform(), .{ .button = .{ .button = 1, .down = true, .x = item.x + @divTrunc(item.w, 2), .y = item.y + @divTrunc(item.h, 2) } }, &placed);
    try std.testing.expectEqual(@as(?usize, 1), s.menu.bar.open);
}
