const std = @import("std");
const Window = @import("ra8").host.history.move.window.Window;

fn opened() Window {
    var window: Window = .{};
    std.debug.assert(window.open());
    return window;
}

test "a claimed commit window can no longer expire" {
    var window = opened();
    try std.testing.expect(window.claim());
    try std.testing.expect(!window.expire() and !window.claim() and !window.settled());
    try std.testing.expect(window.settle());
    try std.testing.expect(window.settled() and !window.expire());
}

test "an expired commit window honors no later COMMIT" {
    var window = opened();
    try std.testing.expect(window.expire());
    try std.testing.expect(!window.claim() and !window.expire() and !window.settled());
}

test "a peer that never became bound opens no window" {
    var window: Window = .{};
    try std.testing.expect(!window.claim() and !window.expire() and !window.settle() and !window.abandon());
    try std.testing.expect(window.unready());
    try std.testing.expect(!window.open() and !window.claim() and !window.unready());
}

test "an opened window can no longer end unready" {
    var window: Window = .{};
    try std.testing.expect(window.open());
    try std.testing.expect(!window.unready() and !window.open());
    try std.testing.expect(window.claim());
}

test "a rename abandoned in flight is never reported settled" {
    var window = opened();
    try std.testing.expect(!window.abandon());
    try std.testing.expect(window.claim());
    try std.testing.expect(window.abandon());
    try std.testing.expect(!window.settle() and !window.settled() and !window.abandon());
}

test "a settled rename can no longer be abandoned" {
    var window = opened();
    try std.testing.expect(window.claim() and window.settle());
    try std.testing.expect(!window.abandon() and !window.settle() and window.settled());
}
