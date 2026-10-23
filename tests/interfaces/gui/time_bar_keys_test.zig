//! The time bar's step-key mapping (RA8EMU-1188): F10, F11 and shift+F11
//! name the bar's over, step and out controls; everything else is no key.
const std = @import("std");
const gui_app = @import("gui_app");
const bar = gui_app.time_bar;
const capture = gui_app.time.bar_capture;

test "the step keys map F10, F11 and shift F11 onto the bar's step controls" {
    try std.testing.expectEqual(@as(?bar.Control, .over), capture.keyControl(capture.key_f10, false));
    try std.testing.expectEqual(@as(?bar.Control, .step), capture.keyControl(capture.key_f11, false));
    try std.testing.expectEqual(@as(?bar.Control, .out), capture.keyControl(capture.key_f11, true));
    try std.testing.expectEqual(@as(?bar.Control, null), capture.keyControl('x', false));
    try std.testing.expectEqual(@as(?bar.Control, .over), capture.keyControl(capture.key_f10, true));
}

test "shift F5 is the reverse-continue key and plain F5 is no step key" {
    try std.testing.expectEqual(@as(?bar.Control, null), capture.keyControl(capture.key_f5, false));
    try std.testing.expectEqual(@as(?bar.Control, null), capture.keyControl(capture.key_f5, true));
}
