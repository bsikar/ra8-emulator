const std = @import("std");
const Window = @import("ra8").host.history.move.window.Window;

test "a claimed commit window can no longer expire" {
    var window: Window = .{};
    try std.testing.expect(window.claim());
    try std.testing.expect(!window.expire() and !window.claim() and !window.settled());
    window.settle();
    try std.testing.expect(window.settled() and !window.expire());
}

test "an expired commit window honors no later COMMIT" {
    var window: Window = .{};
    try std.testing.expect(window.expire());
    try std.testing.expect(!window.claim() and !window.expire() and !window.settled());
}
