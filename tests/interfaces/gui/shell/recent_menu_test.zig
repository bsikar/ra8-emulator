//! Host tests for the File menu's Open Recent items (RA8EMU-1153): the
//! model's own items first, then one item per recent image newest first,
//! each named for the image's file, and an empty list laying in only the
//! model's own.
const std = @import("std");
const gui = @import("gui_app");
const recent_menu = gui.shell.recent_menu;
const menu = gui.menu;
const shell_recents = gui.shell.recents;

test "sync lays the recents in after the model's own items" {
    var list = shell_recents.List{};
    try std.testing.expect(list.add("/a/one.elf"));
    try std.testing.expect(list.add("/a/two.elf"));
    var m = recent_menu.State{ .recents = &list };
    const menus = m.sync();
    try std.testing.expectEqual(@as(usize, 4), menus.len);
    const file = menus[0].items;
    try std.testing.expectEqualStrings("Open ELF...", file[0].label);
    try std.testing.expectEqualStrings("two.elf", file[5].label);
    try std.testing.expect(file[5].divided);
    try std.testing.expect(file[5].action.eql(.{ .recent = 0 }));
    try std.testing.expectEqualStrings("one.elf", file[6].label);
    try std.testing.expect(file[6].action.eql(.{ .recent = 1 }));
    try std.testing.expectEqual(@as(?menu.Shortcut, null), file[6].shortcut);
}

test "sync lays only the model's own items in when the list is empty" {
    var m = recent_menu.State{};
    const menus = m.sync();
    try std.testing.expectEqual(@as(usize, 4), menus.len);
    try std.testing.expectEqual(@as(usize, gui.menu.file.len), menus[0].items.len);
    try std.testing.expectEqualStrings("Run", menus[1].title);
    try std.testing.expectEqualStrings("Board", menus[3].title);
}

test "sync names the image's file, not its whole path" {
    var list = shell_recents.List{};
    try std.testing.expect(list.add("/a/very/deep/thing.elf"));
    var m = recent_menu.State{ .recents = &list };
    const menus = m.sync();
    try std.testing.expectEqualStrings("thing.elf", menus[0].items[5].label);
}
