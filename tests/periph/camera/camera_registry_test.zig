//! Covers src/periph/camera/camera_registry.zig: the `--camera-source`
//! kinds, what each accepts, and the source a spec opens.
const std = @import("std");
const ra8 = @import("ra8");

const camera = ra8.periph.ceu.camera;
const registry = camera.registry;
const allocator = std.testing.allocator;

/// The sensor's FORMAT CONTROL byte as the camera example leaves it.
var format_control: u8 = 0x30;

test "gradient parses with no argument and opens the gradient source" {
    const spec = try registry.parse("gradient");
    try std.testing.expectEqual(registry.Kind.gradient, spec.kind);
    try std.testing.expectEqualStrings("", spec.arg);
    try std.testing.expectEqual(camera.gradient.source().vtable, (try spec.open(allocator, &format_control)).vtable);
    const empty = try registry.parse("gradient:");
    try std.testing.expectEqual(registry.Kind.gradient, empty.kind);
}

test "the default spec is the gradient the CEU always captured" {
    const spec = registry.Spec{};
    try std.testing.expectEqual(registry.Kind.gradient, spec.kind);
    try std.testing.expectEqual(camera.gradient.source().vtable, (try spec.open(allocator, &format_control)).vtable);
}

test "an unknown kind and a stray gradient argument are refused" {
    try std.testing.expectError(error.UnknownCameraSource, registry.parse("camera:0"));
    try std.testing.expectError(error.UnknownCameraSource, registry.parse(""));
    try std.testing.expectError(error.BadValue, registry.parse("gradient:x"));
}

test "image takes a path and refuses to go without one" {
    const spec = try registry.parse("image:shots/frame.png");
    try std.testing.expectEqual(registry.Kind.image, spec.kind);
    try std.testing.expectEqualStrings("shots/frame.png", spec.arg);
    try std.testing.expectError(error.BadValue, registry.parse("image"));
    try std.testing.expectError(error.BadValue, registry.parse("image:"));
}

test "an image that is not there refuses the run when it opens" {
    const spec = try registry.parse("image:/nonexistent/ra8-camera.png");
    try std.testing.expectError(error.FileNotFound, spec.open(allocator, &format_control));
}

test "the report names each source: the gradient by default, a picture by its path" {
    const gradient = try (registry.Spec{}).open(allocator, &format_control);
    try std.testing.expectEqualStrings("synthetic gradient", gradient.label);
    try std.testing.expectEqualStrings("", gradient.detail);
    const named = camera.still.labelled(camera.gradient.source(), "shots/frame.png");
    try std.testing.expectEqualStrings("still image", named.label);
    try std.testing.expectEqualStrings("shots/frame.png", named.detail);
    try std.testing.expectEqual(camera.gradient.source().vtable, named.vtable);
}

test "video takes a path, optionally with loop, and is named by it" {
    const spec = try registry.parse("video:clips/walk.y4m,loop");
    try std.testing.expectEqual(registry.Kind.video, spec.kind);
    try std.testing.expectEqualStrings("clips/walk.y4m,loop", spec.arg);
    try std.testing.expectError(error.BadValue, registry.parse("video"));
    try std.testing.expectError(error.FileNotFound, (try registry.parse("video:/nonexistent/ra8.y4m")).open(allocator, &format_control));
    const named = camera.video.labelled(camera.gradient.source(), "clips/walk.y4m,loop");
    try std.testing.expectEqualStrings("video", named.label);
    try std.testing.expectEqualStrings("clips/walk.y4m,loop", named.detail);
}

test "webcam takes nothing, a device number or a path, and refuses anything else" {
    try std.testing.expectEqual(registry.Kind.webcam, (try registry.parse("webcam")).kind);
    try std.testing.expectEqualStrings("2", (try registry.parse("webcam:2")).arg);
    try std.testing.expectEqualStrings("/dev/v4l/by-id/cam", (try registry.parse("webcam:/dev/v4l/by-id/cam")).arg);
    try std.testing.expectError(error.BadValue, registry.parse("webcam:front"));
    try std.testing.expect(!(try registry.parse("webcam")).allow_webcam);
}
