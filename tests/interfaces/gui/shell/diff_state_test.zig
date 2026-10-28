//! Tests for src/interfaces/gui/shell/diff_state.zig: stepping the compared
//! stop and the refusal note.
const std = @import("std");
const gui_app = @import("gui_app");
const diff_state = gui_app.shell.diff_state;

test "step clamps within the stops the session holds" {
    var state = diff_state.State{ .frames = 3, .pick = 2 };
    try std.testing.expect(state.step(-1));
    try std.testing.expectEqual(@as(?u16, 1), state.pick);
    try std.testing.expect(state.step(-5));
    try std.testing.expectEqual(@as(?u16, 0), state.pick);
    try std.testing.expect(state.step(9));
    try std.testing.expectEqual(@as(?u16, 2), state.pick);
    try std.testing.expect(state.want);
}

test "a refusal leaves an empty view with a note and forgets the pick" {
    var state = diff_state.State{ .frames = 3, .pick = 2 };
    state.refuse();
    try std.testing.expect(state.refused and state.view.picked and !state.view.has_data);
    try std.testing.expectEqual(@as(?u16, null), state.pick);
    try std.testing.expect(state.view.labelSlice().len > 0);
}
