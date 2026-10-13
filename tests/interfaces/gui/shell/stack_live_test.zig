//! The call stack leaf against a live session (RA8EMU-1125): the shell as
//! ra8_gui builds it, its session served in-process. The leaf walks cpu0's
//! chain once the image has loaded, follows a Step and a Pause, and draws
//! in a leaf of the stack kind exactly as the pane draws it.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Live = @import("../live_shell.zig").Live;

const shell_frame = gui_app.shell.frame;
const draw_list = ra8.render.draw_list;
const Live_width = @import("../live_shell.zig").width;
const Live_height = @import("../live_shell.zig").height;
const test_paths = @import("test_paths");

const stack_pane = gui_app.stack_pane;

/// Blinks LED1 twice and then parks in a loop, so it never stops by itself.
const image = "tests/fixtures/gpio/blink.elf";
const slow: u64 = 1;

test "the stack leaf walks cpu0 once the image has loaded" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    try live.untilStack(live.pc());
    try std.testing.expectEqual(@as(?[]const u8, null), live.stack.cores[0].note());
}

test "the stack leaf follows a Step" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    try live.untilStack(live.pc());
    const serial = live.registers.cores[0].serial;
    const reset = live.pc();
    try live.click(.step);
    try live.step();
    try live.untilRead(serial);
    try std.testing.expect(live.pc() != reset);
    try live.untilStack(live.pc());
}

test "the stack leaf follows a Pause" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    const serial = live.registers.cores[0].serial;
    try live.click(.run);
    try live.step();
    try live.step();
    try live.click(.pause);
    try live.step();
    try live.untilRead(serial);
    try live.untilStack(live.shell.status.run.halted.address);
}

test "a leaf switched to the stack kind draws the chain, not its note" {
    var live: Live = undefined;
    try live.open(image, slow);
    defer live.deinit();
    try live.untilStack(live.pc());
    const gpa = std.testing.allocator;
    var solved = try shell_frame.solve(&live.shell.layout, gpa, Live_width, Live_height);
    defer solved.deinit(gpa);
    const placed = solved.panes.items[0];
    var pane = live.shell.layout.pane(placed.index).?;
    pane.kind = .stack;
    pane.core = .cpu0;
    const body = shell_frame.toGeom(shell_frame.bodyOf(placed.area));
    var shown = draw_list.DrawList.init(gpa, Live_width, Live_height);
    defer shown.deinit();
    var shown_target = ra8.render.widget_paint.Target{ .list = &shown };
    const painter = live.panes.painter();
    try painter.paint(painter.context, &shown, &shown_target.paint(), dark, pane, body);
    var want = draw_list.DrawList.init(gpa, Live_width, Live_height);
    defer want.deinit();
    var target = ra8.render.widget_paint.Target{ .list = &want };
    stack_pane.draw(&target.paint(), dark, shell_frame.toList(body), &live.stack.cores[0].now.?, 0);
    try std.testing.expect(want.commands.items.len > 1);
    try std.testing.expectEqual(want.commands.items.len, shown.commands.items.len);
}

test "the stack leaf walks cpu1 once the rig opens the second image" {
    var live: Live = undefined;
    try live.open(test_paths.threadx_dual, slow);
    defer live.deinit();
    try live.openSecond(test_paths.threadx_dual_cpu1);
    // CPU1 halted with no stop event of its own; the shell refreshes its
    // leaves the way a paused run does (shell.run.zig).
    live.registers.refresh();
    live.stack.refresh();
    try live.untilReadOn(1, live.registers.cores[1].serial);
    const pc1 = live.pcOn(1);
    try live.untilStackOn(1, pc1);
    try std.testing.expect(live.stack.cores[1].now.?.count != 0);
    try std.testing.expectEqual(@as(?[]const u8, null), live.stack.cores[1].note());
}
