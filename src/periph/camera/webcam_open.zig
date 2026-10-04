//! Opens `--camera-source webcam[:N|PATH]` (RA8EMU-506): the consent gate
//! first, then the V4L2 node, the format negotiation and the frame source.
//! The device is asked for 640x480; the converter scales whatever it
//! settles on to the size the firmware programmed. This first source reads
//! frames with read() I/O, so a node that only streams is refused for now.
const std = @import("std");
const frame_source = @import("frame_source.zig");
const consent = @import("webcam_consent.zig");
const v4l2 = @import("v4l2_device.zig");
const negotiate = @import("v4l2_negotiate.zig");
const source = @import("webcam_source.zig");

pub const request_width: u32 = 640;
pub const request_height: u32 = 480;

pub const Error = error{ WebcamRefused, NeedsStreaming };

/// Room for a device name built from `webcam:N`.
const Name = [32]u8;

/// Checks a webcam ARG names a device; does not open it.
pub fn device(arg: []const u8) consent.DeviceError![]const u8 {
    var name: Name = undefined;
    return consent.device(&name, arg);
}

/// The open node behind a WebcamSource's capture seam; owns its path.
const Node = struct {
    allocator: std.mem.Allocator,
    fd: v4l2.Fd,
    path: []u8,

    fn capture(self: *Node) source.Capture {
        return .{ .ctx = self, .readFn = read, .closeFn = close };
    }

    fn read(ctx: *anyopaque, out: []u8) bool {
        const self: *Node = @ptrCast(@alignCast(ctx));
        self.fd.readFrame(out) catch return false;
        return true;
    }

    fn close(ctx: *anyopaque) void {
        const self: *Node = @ptrCast(@alignCast(ctx));
        self.fd.close();
        consent.logStop(std.io.getStdErr().writer(), self.path) catch {};
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }
};

/// Opens the webcam, asking on the terminal unless `allow` is set.
pub fn open(allocator: std.mem.Allocator, arg: []const u8, allow: bool, format_control: *const u8) !frame_source.FrameSource {
    const grant: consent.Grant = if (allow) .allowed else .ask;
    return openWith(allocator, arg, grant, std.io.getStdIn().reader(), std.io.getStdErr().writer(), format_control);
}

/// `open` with the consent question's reader and writer passed in.
pub fn openWith(allocator: std.mem.Allocator, arg: []const u8, grant: consent.Grant, reader: anytype, writer: anytype, format_control: *const u8) !frame_source.FrameSource {
    var name: Name = undefined;
    const named = try consent.device(&name, arg);
    if (consent.decide(grant, named, reader, writer) == .refused) return error.WebcamRefused;
    const node = try allocator.create(Node);
    errdefer allocator.destroy(node);
    const path = try allocator.dupe(u8, named);
    errdefer allocator.free(path);
    node.* = .{ .allocator = allocator, .fd = try v4l2.Fd.open(path), .path = path };
    errdefer node.fd.close();
    const agreed = try negotiate.negotiate(node.fd.device(), request_width, request_height);
    if (!agreed.read_io) return error.NeedsStreaming;
    const webcam = try source.WebcamSource.open(allocator, node.capture(), agreed, path, format_control);
    consent.logStart(writer, path) catch {};
    return webcam.source();
}
