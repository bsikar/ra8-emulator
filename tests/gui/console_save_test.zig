//! Covers src/gui/console_save.zig: a save writes the channel's stamped log
//! to console-sciN.txt, and only a click on the SAVE tab saves.
const std = @import("std");
const ra8 = @import("ra8");
const console_log = ra8.gui.console_log;
const console_pick = ra8.gui.console_pick;
const console_save = ra8.gui.console_save;
const Rect = ra8.gui.draw_list.Rect;

const area = Rect{ .x = 0, .y = 100, .w = 400, .h = 60 };

fn read(dir: std.fs.Dir, name: []const u8, buffer: []u8) ![]const u8 {
    return dir.readFile(name, buffer);
}

test "the file is named for its channel" {
    var buffer: [console_save.name_len]u8 = undefined;
    try std.testing.expectEqualStrings("console-sci8.txt", console_save.fileName(&buffer, 8));
    try std.testing.expectEqualStrings("console-sci10.txt", console_save.fileName(&buffer, 10));
}

test "a save writes the stamped log the way console_log formats it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var log = console_log.Log.init(std.testing.allocator, 4);
    defer log.deinit();
    try log.feedAll("boot\n", 1_500_000);
    var want = std.ArrayList(u8).init(std.testing.allocator);
    defer want.deinit();
    try log.save(want.writer(), true);
    try console_save.save(std.testing.io, tmp.dir, 3, &log);
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(want.items, try read(tmp.dir, "console-sci3.txt", &buffer));
}

test "only a click on the SAVE tab saves the shown channel" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var logs: [2]console_log.Log = undefined;
    for (&logs) |*log| log.* = .init(std.testing.allocator, 4);
    defer for (&logs) |*log| log.deinit();
    try logs[1].feedAll("hi\n", 0);
    try std.testing.expect(!console_save.click(area, area.x + 1, area.y + 1, std.testing.io, tmp.dir, &logs, 1));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("console-sci1.txt", .{}));
    const tab = console_pick.saveTab(area);
    try std.testing.expect(console_save.click(area, tab.x + 1, tab.y + 1, std.testing.io, tmp.dir, &logs, 1));
    try tmp.dir.access("console-sci1.txt", .{});
    // Without a project directory the click is still taken, and nothing is written.
    try std.testing.expect(console_save.click(area, tab.x + 1, tab.y + 1, std.testing.io, null, &logs, 0));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("console-sci0.txt", .{}));
}
