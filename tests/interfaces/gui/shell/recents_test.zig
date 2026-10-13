//! Covers src/interfaces/gui/shell/recents.zig.
const std = @import("std");
const gui = @import("gui_app");
const shell_recents = gui.shell.recents;

test "add keeps the newest first" {
    var list = shell_recents.List{};
    try std.testing.expect(list.add("/a/one.elf"));
    try std.testing.expect(list.add("/a/two.elf"));
    try std.testing.expectEqualStrings("/a/two.elf", list.path(0).?);
    try std.testing.expectEqualStrings("/a/one.elf", list.path(1).?);
    try std.testing.expectEqual(@as(?[]const u8, null), list.path(2));
}

test "add moves a duplicate to the front" {
    var list = shell_recents.List{};
    try std.testing.expect(list.add("/a/one.elf"));
    try std.testing.expect(list.add("/a/two.elf"));
    try std.testing.expect(list.add("/a/one.elf"));
    try std.testing.expectEqualStrings("/a/one.elf", list.path(0).?);
    try std.testing.expectEqualStrings("/a/two.elf", list.path(1).?);
    try std.testing.expectEqual(@as(usize, 2), list.len);
}

test "add holds the last ten" {
    var list = shell_recents.List{};
    var buf: [16]u8 = undefined;
    for (0..12) |n| {
        const name = try std.fmt.bufPrint(&buf, "/a/{d}.elf", .{n});
        try std.testing.expect(list.add(name));
    }
    try std.testing.expectEqual(@as(usize, 10), list.len);
    try std.testing.expectEqualStrings("/a/11.elf", list.path(0).?);
    try std.testing.expectEqualStrings("/a/2.elf", list.path(9).?);
}

test "add refuses a path past its room" {
    var list = shell_recents.List{};
    var long_name: [513]u8 = @splat('x');
    try std.testing.expect(!list.add(&long_name));
}

test "a saved list round-trips" {
    var list = shell_recents.List{};
    try std.testing.expect(list.add("/a/one.elf"));
    try std.testing.expect(list.add("/a/two.elf"));
    var data: [shell_recents.max * (shell_recents.path_max + 1)]u8 = undefined;
    const text = try encodeForTest(list, &data);
    const restored = shell_recents.parse(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/a/two.elf", restored.path(0).?);
    try std.testing.expectEqualStrings("/a/one.elf", restored.path(1).?);
}

test "a corrupt saved file restores nothing" {
    try std.testing.expectEqual(@as(?shell_recents.List, null), shell_recents.parse("nonsense"));
}

fn encodeForTest(list: shell_recents.List, buf: []u8) ![]const u8 {
    var w: usize = 0;
    for (0..list.len) |at| {
        const written = try std.fmt.bufPrint(buf[w..], "{s}\n", .{list.path(at).?});
        w += written.len;
    }
    return buf[0..w];
}
