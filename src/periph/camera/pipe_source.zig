//! Raw frames from a pipe as the camera (RA8EMU-584):
//! `--camera-source pipe:<path|->,<w>x<h>,<rgb24|yuyv|rgb565>`.
//!
//! The pipe is read without blocking. Each capture drains what the writer
//! has sent so far, keeps the newest whole frame and shows it; a frame cut
//! short waits for the rest. Before the first frame arrives the capture is
//! black. A FIFO with no writer yet reads 0 bytes, so a 0-byte read only
//! counts as the writer closing once data has arrived; after that the last
//! frame is held and one line says so. The run never waits on the writer.
//! Windows named pipes are RA8EMU-585; until then the kind refuses there.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const frame_source = @import("frame_source.zig");
const converted = @import("converted_source.zig");
const decoded = @import("decoded_image.zig");
const still = @import("image_source.zig");
pub const raw = @import("pipe_frame.zig");

/// The most whole frames one capture drains, so a writer faster than the
/// run (`cat /dev/zero`) cannot hold a capture forever.
pub const max_frames_per_capture: usize = 64;

/// Name a pipe source after its argument for the end-of-run report.
pub fn labelled(source: frame_source.FrameSource, arg: []const u8) frame_source.FrameSource {
    var named = source;
    named.label = "pipe";
    named.detail = arg;
    return named;
}

pub const PipeSource = struct {
    allocator: std.mem.Allocator,
    fd: posix.fd_t,
    owns_fd: bool,
    arg: raw.Arg,
    /// The frame being received, and the newest whole one.
    pending: []u8,
    latest: []u8,
    filled: usize = 0,
    fresh: bool = false,
    seen_data: bool = false,
    closed: bool = false,
    /// Whole frames received over the run.
    frames: u64 = 0,
    image: decoded.Image,
    converted: converted.Converted,
    format_control: *const u8,

    /// Open the named pipe, or standard input for "-", without blocking.
    pub fn load(allocator: std.mem.Allocator, text: []const u8, format_control: *const u8) !*PipeSource {
        if (builtin.os.tag == .windows) {
            std.debug.print("--camera-source pipe: Windows named pipes are not supported yet\n", .{});
            return error.Unsupported;
        } else {
            const arg = try raw.parseArg(text);
            const stdin = std.mem.eql(u8, arg.path, "-");
            const fd = if (stdin) posix.STDIN_FILENO else try posix.open(arg.path, .{ .ACCMODE = .RDONLY, .NONBLOCK = true }, 0);
            errdefer if (!stdin) posix.close(fd);
            return fromFd(allocator, fd, !stdin, arg, format_control);
        }
    }

    /// Read frames from `fd`, which is made non-blocking; closed at the end
    /// only when `owns_fd`.
    pub fn fromFd(allocator: std.mem.Allocator, fd: posix.fd_t, owns_fd: bool, arg: raw.Arg, format_control: *const u8) !*PipeSource {
        const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
        const nonblock: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(fd, posix.F.SETFL, flags | nonblock);
        const image = try decoded.Image.alloc(allocator, arg.width, arg.height);
        errdefer image.deinit(allocator);
        const pending = try allocator.alloc(u8, arg.frameBytes());
        errdefer allocator.free(pending);
        const latest = try allocator.alloc(u8, arg.frameBytes());
        errdefer allocator.free(latest);
        const self = try allocator.create(PipeSource);
        self.* = .{
            .allocator = allocator,
            .fd = fd,
            .owns_fd = owns_fd,
            .arg = arg,
            .pending = pending,
            .latest = latest,
            .image = image,
            .converted = .{ .input = image.frame(), .format = still.formatFor(format_control.*) },
            .format_control = format_control,
        };
        @memset(image.pixels, .{ .r = 0, .g = 0, .b = 0 });
        return self;
    }

    pub fn source(self: *PipeSource) frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable };
    }

    /// Take whatever the writer has sent, never waiting for more.
    pub fn drain(self: *PipeSource) void {
        var whole: usize = 0;
        while (!self.closed and whole < max_frames_per_capture) {
            const got = posix.read(self.fd, self.pending[self.filled..]) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return self.hangUp(),
            };
            if (got == 0) return if (self.seen_data) self.hangUp();
            self.seen_data = true;
            self.filled += got;
            if (self.filled < self.pending.len) continue;
            std.mem.swap([]u8, &self.pending, &self.latest);
            self.filled = 0;
            self.fresh = true;
            self.frames += 1;
            whole += 1;
        }
    }

    fn hangUp(self: *PipeSource) void {
        self.closed = true;
        std.debug.print("--camera-source pipe:{s}: the writer closed after {d} frames; holding the last one\n", .{ self.arg.path, self.frames });
    }

    const vtable = frame_source.FrameSource.VTable{ .frame = frame, .fill = fill, .close = close };

    fn frame(context: *anyopaque, when: u64, shape: frame_source.Shape) void {
        const self: *PipeSource = @ptrCast(@alignCast(context));
        self.drain();
        if (self.fresh) raw.toRgb(self.arg.format, self.latest, self.image.pixels);
        self.fresh = false;
        self.converted.format = still.formatFor(self.format_control.*);
        self.converted.source().frame(when, shape);
    }

    fn fill(context: *anyopaque, row: u32, column: u32, out: []u8) void {
        const self: *PipeSource = @ptrCast(@alignCast(context));
        self.converted.source().fill(row, column, out);
    }

    fn close(context: *anyopaque) void {
        const self: *PipeSource = @ptrCast(@alignCast(context));
        const allocator = self.allocator;
        if (self.owns_fd) posix.close(self.fd);
        allocator.free(self.pending);
        allocator.free(self.latest);
        self.image.deinit(allocator);
        allocator.destroy(self);
    }
};
