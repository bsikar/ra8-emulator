//! Tests for smooth rewind front-end wiring (Slice 22.4): LCD history rewind frame cache,
//! keyboard controls (Shift+Space, Left/Right), and pane busy state.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const Rig = @import("local_rig.zig").Rig;

const shell_time = gui_app.shell.time;
const time_bar_capture = gui_app.time.bar_capture;
const panes = gui_app.shell.panes;
const Status = gui_app.status.bar.Status;

const image_path = "tests/fixtures/gpio/blink.elf";

test "Time.trackKeyFull maps Shift+Space to reverse play and Left/Right to seek" {
    var rig: Rig = undefined;
    try rig.open(image_path);
    defer rig.deinit();

    var status: Status = .{};
    try rig.load(&status, image_path);

    var time = shell_time.Time{};

    // Shift+Space while halted triggers reverse play
    try std.testing.expect(time.trackKeyFull(time_bar_capture.key_space, true, &status, &rig.link));
    try std.testing.expect(time.run.lit);

    // Space while running pauses
    try std.testing.expect(time.trackKeyFull(time_bar_capture.key_space, false, &status, &rig.link));
    try std.testing.expect(!time.run.lit);

    // Left arrow invokes seek "prev"
    try std.testing.expect(time.trackKeyFull(time_bar_capture.key_left, false, &status, &rig.link));

    // Right arrow invokes seek "next"
    try std.testing.expect(time.trackKeyFull(time_bar_capture.key_right, false, &status, &rig.link));
}

test "panes busy state defaults to false and toggles cleanly" {
    var p = panes.Panes{};
    try std.testing.expect(!p.busy);
    p.busy = true;
    try std.testing.expect(p.busy);
    p.busy = false;
    try std.testing.expect(!p.busy);
}
