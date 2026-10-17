//! Host tests for reading the image ra8_gui's session starts on: one named
//! on the command line, and a copy of one a window event names.
const std = @import("std");
const gui_app = @import("gui_app");
const first_image = gui_app.shell.first_image;

const image = "tests/fixtures/fpu/fp_basic.elf";
const missing = "tests/fixtures/no-such.elf";

test "an image named on the command line is read, and a missing one is not" {
    const got = first_image.read(std.testing.allocator, std.testing.io, image).?;
    defer std.testing.allocator.free(got.bytes);
    try std.testing.expectEqualStrings(image, got.path);
    try std.testing.expect(got.bytes.len > 0);
    try std.testing.expectEqual(@as(?first_image.Image, null), first_image.read(std.testing.allocator, std.testing.io, missing));
}

test "a copied path outlives the event's, and a missing one keeps nothing" {
    var event_path = image.*;
    const got = first_image.copy(std.testing.allocator, std.testing.io, &event_path).?;
    defer std.testing.allocator.free(got.bytes);
    defer std.testing.allocator.free(got.path);
    @memset(&event_path, 'x');
    try std.testing.expectEqualStrings(image, got.path);
    try std.testing.expectEqual(@as(?first_image.Image, null), first_image.copy(std.testing.allocator, std.testing.io, missing));
}
