//! Host tests for the shell's saved window geometry (RA8EMU-966): a
//! round-trip through the store's text, and a missing or corrupt file
//! restoring nothing.
const std = @import("std");
const gui_app = @import("gui_app");
const platform = gui_app.platform;
const window_store = gui_app.shell.window_store;

test "the text round-trips the geometry" {
    const saved = platform.WindowState{ .width = 1280, .height = 860, .x = -4, .y = 31, .fullscreen = true };
    var buf: [256]u8 = undefined;
    const text = try encode(saved, &buf);
    const parsed = window_store.parse(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(saved, parsed);
}

test "a state with no position round-trips without one" {
    const saved = platform.WindowState{ .width = 800, .height = 500 };
    var buf: [256]u8 = undefined;
    const text = try encode(saved, &buf);
    const parsed = window_store.parse(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(saved, parsed);
    try std.testing.expect(parsed.x == null and parsed.y == null);
}

test "a corrupt save is refused, not a crash" {
    const bad = [_][]const u8{
        "",
        "banana",
        "size 0 500",
        "size 800 0",
        "size 800 500 pos 4",
        "size 800 500 pos 4 banana",
        "size 800 500 full banana",
        "size 800 500 full 2",
        "size 800 500 full 1 trailing",
        "size 800 500 pos 4 31",
    };
    for (bad) |bytes| {
        try std.testing.expect(window_store.parse(bytes) == null);
    }
}

test "save writes the geometry and restore reads it back" {
    // A scratch dir under the process cwd; the store joins it to the file.
    const dir = "ra8_window_store_test_tmp";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    const store = window_store.Store{ .io = std.testing.io, .allocator = std.testing.allocator, .dir = dir };
    const saved = platform.WindowState{ .width = 1072, .height = 640, .x = 12, .y = -8, .fullscreen = false };
    store.save(saved);
    const read_back = store.restore() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(saved, read_back);
}

test "a corrupt file restores nothing" {
    const dir = "ra8_window_store_test_tmp";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = dir ++ "/" ++ window_store.file_name, .data = "banana" });
    const store = window_store.Store{ .io = std.testing.io, .allocator = std.testing.allocator, .dir = dir };
    try std.testing.expect(store.restore() == null);
}

test "restore with no directory is null" {
    const store = window_store.Store{ .io = std.testing.io, .allocator = std.testing.allocator, .dir = null };
    try std.testing.expect(store.restore() == null);
    // save() is then a no-op, not a crash.
    store.save(.{ .width = 800, .height = 500 });
}

fn encode(state: platform.WindowState, buf: []u8) ![]const u8 {
    var w: usize = 0;
    var part = try std.fmt.bufPrint(buf[w..], "size {d} {d}", .{ state.width, state.height });
    w += part.len;
    if (state.x != null and state.y != null) {
        part = try std.fmt.bufPrint(buf[w..], " pos {d} {d}", .{ state.x.?, state.y.? });
        w += part.len;
    }
    part = try std.fmt.bufPrint(buf[w..], " full {d}", .{@intFromBool(state.fullscreen)});
    w += part.len;
    return buf[0..w];
}
