//! Covers src/gui/platform.zig: Text keeps the first bytes of the UTF-8 it
//! was given.
const std = @import("std");
const ra8 = @import("ra8");
const Text = ra8.gui.platform.Text;

test "text keeps what it was given" {
    const text = Text.of("Hi!");
    try std.testing.expectEqualStrings("Hi!", text.slice());
}

test "text longer than its buffer keeps the first bytes" {
    const text = Text.of("0123456789");
    try std.testing.expectEqualStrings("01234567", text.slice());
}
