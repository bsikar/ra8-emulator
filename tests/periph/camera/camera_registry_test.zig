//! Covers src/periph/camera/camera_registry.zig: the `--camera-source`
//! kinds, what each accepts, and the source a spec opens.
const std = @import("std");
const ra8 = @import("ra8");

const camera = ra8.periph.ceu.camera;
const registry = camera.registry;

test "gradient parses with no argument and opens the gradient source" {
    const spec = try registry.parse("gradient");
    try std.testing.expectEqual(registry.Kind.gradient, spec.kind);
    try std.testing.expectEqualStrings("", spec.arg);
    try std.testing.expectEqual(camera.gradient.source().vtable, spec.open().vtable);
    const empty = try registry.parse("gradient:");
    try std.testing.expectEqual(registry.Kind.gradient, empty.kind);
}

test "the default spec is the gradient the CEU always captured" {
    const spec = registry.Spec{};
    try std.testing.expectEqual(registry.Kind.gradient, spec.kind);
    try std.testing.expectEqual(camera.gradient.source().vtable, spec.open().vtable);
}

test "an unknown kind and a stray gradient argument are refused" {
    try std.testing.expectError(error.UnknownCameraSource, registry.parse("webcam:0"));
    try std.testing.expectError(error.UnknownCameraSource, registry.parse(""));
    try std.testing.expectError(error.BadValue, registry.parse("gradient:x"));
}
