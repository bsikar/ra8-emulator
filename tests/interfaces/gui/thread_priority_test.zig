//! Covers src/interfaces/gui/thread_priority.zig: the outcome follows the host's
//! raise, and a host without one leaves the thread unchanged.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const thread_priority = ra8.gui.thread_priority;

fn took() bool {
    return true;
}

fn refused() bool {
    return false;
}

test "the outcome is the host raise's answer" {
    try std.testing.expectEqual(thread_priority.Outcome.raised, thread_priority.raiseWith(&took));
    try std.testing.expectEqual(thread_priority.Outcome.refused, thread_priority.raiseWith(&refused));
}

test "no host raise leaves the thread unchanged" {
    try std.testing.expectEqual(thread_priority.Outcome.unchanged, thread_priority.raiseWith(null));
}

test "linux has no raise to make, so the engine stays as it is" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    try std.testing.expect(thread_priority.host() == null);
    try std.testing.expectEqual(thread_priority.Outcome.unchanged, thread_priority.raiseEngine());
}
