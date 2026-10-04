//! The camera sources `--camera-source KIND[:ARG]` can name (RA8EMU-525).
//!
//! `gradient` takes no argument; `image:PATH` captures a still picture
//! (RA8EMU-529); `video:PATH[,loop]` plays a Y4M clip by emulated time
//! (RA8EMU-499); `pipe:<path|->,<w>x<h>,<format>` reads raw frames from a
//! named pipe or stdin (RA8EMU-584); `webcam[:N|PATH]` captures the Linux
//! host camera after the consent gate (RA8EMU-506). An unknown kind is refused when the command line is read, not
//! when the camera first captures, so a typo never runs on the gradient.
const std = @import("std");
const frame_source = @import("frame_source.zig");
const gradient = @import("gradient_source.zig");
const image = @import("image_source.zig");
const video = @import("video_source.zig");
const pipe = @import("pipe_source.zig");
const webcam = @import("webcam_open.zig");

pub const Kind = enum {
    gradient,
    image,
    video,
    pipe,
    webcam,
};

/// One parsed `--camera-source`. The default is the gradient, which is
/// what the CEU captures when the flag is not given at all.
pub const Spec = struct {
    kind: Kind = .gradient,
    arg: []const u8 = "",
    /// `--allow-webcam`: open a webcam without asking on the terminal.
    allow_webcam: bool = false,

    /// The source this spec names, ready to hand to the CEU. A source that
    /// converts reads the sensor's FORMAT CONTROL byte at each capture. A
    /// picture that cannot be read or decoded says why and refuses the run.
    pub fn open(self: Spec, allocator: std.mem.Allocator, format_control: *const u8) !frame_source.FrameSource {
        return switch (self.kind) {
            .gradient => gradient.source(),
            .image => image.labelled((image.ImageSource.load(allocator, self.arg, format_control) catch |err| {
                std.debug.print("--camera-source image:{s}: {s}\n", .{ self.arg, @errorName(err) });
                return err;
            }).source(), self.arg),
            .video => video.labelled((video.VideoSource.load(allocator, self.arg, format_control) catch |err| {
                std.debug.print("--camera-source video:{s}: {s}\n", .{ self.arg, @errorName(err) });
                return err;
            }).source(), self.arg),
            .pipe => pipe.labelled((pipe.PipeSource.load(allocator, self.arg, format_control) catch |err| {
                std.debug.print("--camera-source pipe:{s}: {s}\n", .{ self.arg, @errorName(err) });
                return err;
            }).source(), self.arg),
            .webcam => webcam.open(allocator, self.arg, self.allow_webcam, format_control) catch |err| {
                std.debug.print("--camera-source webcam:{s}: {s}\n", .{ self.arg, @errorName(err) });
                return err;
            },
        };
    }
};

pub const ParseError = error{ UnknownCameraSource, BadValue };

/// `KIND` or `KIND:ARG`. A kind that takes no argument refuses one,
/// `image` and `video` refuse to go without their path, and `pipe` needs
/// its path, size and format.
pub fn parse(text: []const u8) ParseError!Spec {
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const name = if (colon) |at| text[0..at] else text;
    const arg = if (colon) |at| text[at + 1 ..] else "";
    const kind = std.meta.stringToEnum(Kind, name) orelse return error.UnknownCameraSource;
    switch (kind) {
        .gradient => if (arg.len != 0) return error.BadValue,
        .image, .video => if (arg.len == 0) return error.BadValue,
        .pipe => _ = pipe.raw.parseArg(arg) catch return error.BadValue,
        .webcam => _ = webcam.device(arg) catch return error.BadValue,
    }
    return .{ .kind = kind, .arg = arg };
}
