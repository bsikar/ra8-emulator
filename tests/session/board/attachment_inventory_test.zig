//! Every reachable arena field is saved or named as target wiring.
const std = @import("std");
const ra8 = @import("ra8");
const attachments = ra8.session.board.state.attachments;

test "attachment strict reflected known arena fields are classified" {
    try std.testing.expect(comptime attachments.inventory.complete());
}
