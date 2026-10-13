//! Host tests for the shell's memory map leaf (src/interfaces/gui/
//! shell/map.zig, RA8EMU-781): an image read lays its sections over the
//! board's regions, a read that fails flags the leaf and keeps the map that
//! was there, and a second build replaces the first one's bytes.
const std = @import("std");
const gui_app = @import("gui_app");
const shell_map = gui_app.shell.map;
const image_path = "tests/fixtures/sections/fault_crashlog_hil.elf";

test "the shell map leaf reads the image and lays its sections" {
    var state: shell_map.State = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer state.deinit();
    state.build(image_path);
    try std.testing.expect(!state.failed);
    const layout = state.layout orelse return error.TestUnexpectedResult;
    try std.testing.expect(layout.blocks.len > 0);
    try std.testing.expect(state.bytes.?.len > 0);
}

test "a read that fails flags the leaf and keeps the map that was there" {
    var state: shell_map.State = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer state.deinit();
    state.build(image_path);
    const first = state.layout.?;
    state.build("tests/fixtures/sections/does_not_exist.elf");
    try std.testing.expect(state.failed);
    try std.testing.expectEqual(first.blocks.len, state.layout.?.blocks.len);
}

test "a second build replaces the first one's bytes" {
    var state: shell_map.State = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    defer state.deinit();
    state.build(image_path);
    const old = state.bytes.?;
    state.build(image_path);
    try std.testing.expect(old.ptr != state.bytes.?.ptr);
    try std.testing.expect(!state.failed);
}
