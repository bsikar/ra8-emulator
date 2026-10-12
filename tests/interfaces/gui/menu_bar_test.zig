//! Host tests for the in-window menu bar (RA8EMU-968): where the strip and
//! its drop-downs sit, what a press opens, fires or closes, the disabled and
//! divided rows, Quit leaving the bar on macOS, hover switching, and a draw
//! pass with a drop-down out.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const draw_list = ra8.render.draw_list;
const font = ra8.render.font;
const menu_bar = gui_app.menu_bar;
const menu = gui_app.menu;
const colors = gui_app.colors;

const Bar = menu_bar.Bar;
const Menu = menu_bar.Menu;
const dark = &colors.palettes.dark;

const linux: std.Target.Os.Tag = .linux;
const macos: std.Target.Os.Tag = .macos;
const width = 800;
const loaded = Menu{ .bar = .{}, .state = .{ .loaded = true }, .os = linux };
const idle = Menu{ .bar = .{}, .state = .{}, .os = linux };

/// The middle of title `index`, where a press opens it.
fn titleMid(index: usize) draw_list.Rect {
    const at = menu_bar.title(width, index);
    return .{ .x = at.x + @divFloor(at.w, 2), .y = at.y + @divFloor(at.h, 2), .w = 0, .h = 0 };
}

test "the strip's height clears a title's text" {
    try std.testing.expect(menu_bar.height > 16);
}

test "a press on a title opens its drop-down, and again closes it" {
    var bar = Bar{};
    const mid = titleMid(0);
    const first = menu_bar.press(&bar, loaded, width, mid.x, mid.y);
    try std.testing.expect(std.meta.activeTag(first) == .taken);
    try std.testing.expectEqual(@as(?usize, 0), bar.open);
    const second = menu_bar.press(&bar, loaded, width, mid.x, mid.y);
    try std.testing.expect(std.meta.activeTag(second) == .taken);
    try std.testing.expectEqual(@as(?usize, null), bar.open);
    // Run's title starts where File's ends: two pads and "File".
    try std.testing.expectEqual(2 * menu_bar.pad + 4 * 8, menu_bar.title(width, 1).x);
}

test "an enabled item fires its action and closes the menu" {
    var bar = Bar{ .open = 0 };
    const at = menu_bar.row(width, 0, 0, linux);
    const did = menu_bar.press(&bar, loaded, width, at.x + 40, at.y + 2);
    try std.testing.expect(std.meta.activeTag(did) == .fire);
    try std.testing.expect(did.fire.eql(.{ .command = .open_elf }));
    try std.testing.expectEqual(@as(?usize, null), bar.open);
}

test "a disabled item takes the press and never fires" {
    var bar = Bar{ .open = 1 };
    const at = menu_bar.row(width, 1, 0, linux); // Run, with nothing loaded
    const did = menu_bar.press(&bar, idle, width, at.x + 40, at.y + 2);
    try std.testing.expect(std.meta.activeTag(did) == .taken);
    try std.testing.expectEqual(@as(?usize, 1), bar.open);
}

test "a click outside closes an open drop-down and falls through when bare" {
    var bar = Bar{ .open = 0 };
    try std.testing.expect(std.meta.activeTag(menu_bar.press(&bar, loaded, width, 400, 300)) == .taken);
    try std.testing.expectEqual(@as(?usize, null), bar.open);
    try std.testing.expect(std.meta.activeTag(menu_bar.press(&bar, loaded, width, 400, 300)) == .missed);
}

test "a press with nothing open falls through to the panes" {
    var bar = Bar{};
    try std.testing.expect(std.meta.activeTag(menu_bar.press(&bar, loaded, width, 400, 10)) == .missed);
}

test "escape closes a drop-down and reports one was out" {
    var bar = Bar{ .open = 2 };
    try std.testing.expect(menu_bar.escape(&bar));
    try std.testing.expectEqual(@as(?usize, null), bar.open);
    try std.testing.expect(!menu_bar.escape(&bar));
}

test "hover moves the open drop-down across the titles" {
    var bar = Bar{ .open = 0 };
    menu_bar.hover(&bar, width, menu_bar.title(width, 2).x + 8);
    try std.testing.expectEqual(@as(?usize, 2), bar.open);
    menu_bar.hover(&bar, width, 400);
    try std.testing.expectEqual(@as(?usize, 2), bar.open);
}

test "rows stack with two pixels of air over a divided row" {
    const first = menu_bar.row(width, 0, 0, linux);
    const second = menu_bar.row(width, 0, 1, linux);
    const quit = menu_bar.row(width, 0, 2, linux);
    try std.testing.expectEqual(first.y + menu_bar.row_h, second.y);
    try std.testing.expectEqual(second.y + menu_bar.row_h + menu_bar.divide, quit.y);
    try std.testing.expectEqual(1 + 3 * menu_bar.row_h + menu_bar.divide, menu_bar.drop(width, 0, linux).h);
    try std.testing.expect(menu_bar.drop(width, 0, linux).contains(quit.x + 2, quit.y + 1));
}

test "macOS leaves Quit out of File" {
    const mac: Menu = .{ .state = .{ .loaded = true }, .os = macos };
    try std.testing.expectEqual(menu_bar.drop(width, 0, linux).h - menu_bar.row_h - menu_bar.divide, menu_bar.drop(width, 0, macos).h);
    try std.testing.expect(menu_bar.dropWidth(0, macos) < menu_bar.dropWidth(0, linux));
    // With Quit hidden, the drop-down's second row is Close, and it fires.
    var bar = Bar{};
    const mid = titleMid(0);
    _ = menu_bar.press(&bar, mac, width, mid.x, mid.y);
    const at = menu_bar.row(width, 0, 1, macos);
    const did = menu_bar.press(&bar, mac, width, at.x + 40, at.y + 2);
    try std.testing.expect(std.meta.activeTag(did) == .fire);
    try std.testing.expect(did.fire.eql(.{ .command = .close }));
}

test "the drop-down is wide enough for every shown label and its shortcut" {
    var buf: [16]u8 = undefined;
    for (0..menu.bar.len) |index| {
        const box = menu_bar.drop(width, index, linux);
        for (menu.bar[index].items) |item| {
            if (!menu.shows(item, linux)) continue;
            var need: i32 = 3 * menu_bar.pad + @as(i32, @intCast(font.textWidth(item.label.len)));
            if (item.shortcut) |bound| {
                const text = try menu.text(bound, linux, &buf);
                need += @as(i32, @intCast(font.textWidth(text.len)));
            }
            try std.testing.expect(need <= box.w);
        }
    }
}

test "the strip draws bare and with a drop-down open" {
    const gpa = std.testing.allocator;
    var list = draw_list.DrawList.init(gpa, width, menu_bar.height + 200);
    defer list.deinit();
    try menu_bar.draw(&list, dark, loaded, width);
    try std.testing.expect(list.commands.items.len > 0);
    list.clear();
    try menu_bar.draw(&list, dark, .{ .bar = .{ .open = 0 }, .state = .{ .loaded = true }, .os = linux }, width);
    // The open pass drew the drop-down over the strip's fills.
    try std.testing.expect(list.commands.items.len > 3);
}
