//! Covers src/periph/camera/v4l2_device.zig with ordinary device nodes:
//! nothing here needs or opens a camera.
const std = @import("std");
const ra8 = @import("ra8");
const webcam = ra8.periph.ceu.camera.webcam;
const v4l2 = webcam.device;

test "a missing node is refused" {
    if (!v4l2.supported) return error.SkipZigTest;
    try std.testing.expectError(error.OpenFailed, v4l2.Fd.open("/nonexistent/ra8-video9"));
}

test "a node that is not V4L2 fails QUERYCAP, so negotiation refuses it" {
    if (!v4l2.supported) return error.SkipZigTest;
    var fd = try v4l2.Fd.open("/dev/null");
    defer fd.close();
    try std.testing.expectError(error.QueryFailed, webcam.negotiate.negotiate(fd.device(), 320, 240));
}

test "read capture fills a whole frame, and a short read is reported" {
    if (!v4l2.supported) return error.SkipZigTest;
    var zero = try v4l2.Fd.open("/dev/zero");
    defer zero.close();
    var frame = [_]u8{0xAA} ** 64;
    try zero.readFrame(&frame);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 64), &frame);
    var empty = try v4l2.Fd.open("/dev/null");
    defer empty.close();
    try std.testing.expectError(error.ShortFrame, empty.readFrame(&frame));
}

test "hosts without V4L2 refuse to open anything" {
    if (v4l2.supported) return error.SkipZigTest;
    try std.testing.expectError(error.Unsupported, v4l2.Fd.open("/dev/video0"));
}
