//! Platform decorator intercepting poll and present for scripting and video capture (RA8EMU-1120).
const std = @import("std");
const platform_mod = @import("../platform.zig");
const raster = @import("ra8_render").raster;
const draw_list = @import("ra8_render").draw_list;
const runner_mod = @import("../script/runner.zig");
const writer_mod = @import("writer.zig");
const cursor_mod = @import("cursor.zig");
const shell_loop = @import("../shell/loop.zig");

const Framebuffer = raster.Framebuffer;
const Platform = platform_mod.Platform;
const Event = platform_mod.Event;
const Size = platform_mod.Size;
const Appearance = platform_mod.Appearance;

pub const Capture = struct {
    allocator: std.mem.Allocator,
    inner: Platform,
    runner: ?*runner_mod.Runner = null,
    writer: ?*writer_mod.Writer = null,
    shell: ?*const shell_loop.Shell = null,
    show_cursor: bool = false,
    fps: u32 = 30,

    frame_counter: u32 = 0,
    polled_this_frame: bool = false,
    last_video_frame: ?u32 = null,
    overlay_frame: ?Framebuffer = null,

    pub fn init(allocator: std.mem.Allocator, inner: Platform) Capture {
        return .{
            .allocator = allocator,
            .inner = inner,
        };
    }

    pub fn deinit(self: *Capture) void {
        if (self.overlay_frame) |*of| of.deinit(self.allocator);
    }

    pub fn bind(self: *Capture, shell: *const shell_loop.Shell) void {
        self.shell = shell;
    }

    pub fn unbind(self: *Capture) void {
        self.shell = null;
    }

    pub fn platform(self: *Capture) Platform {
        return .{
            .ctx = self,
            .vtable = &.{
                .poll = poll,
                .size = size,
                .scale = scale,
                .present = present,
                .show = show,
                .interval = interval,
                .set_vsync = setVsync,
                .refresh = refresh,
                .appearance = appearance,
                .focus = focus,
                .open_image = openImage,
                .open_profile = openProfile,
            },
        };
    }

    fn poll(ctx: *anyopaque) ?Event {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        if (!self.polled_this_frame) {
            self.polled_this_frame = true;
            if (self.runner) |runner| {
                const s = self.inner.size();
                const w: i32 = @intCast(s.width);
                const h: i32 = @intCast(s.height);
                const virtual_ns = @as(u64, self.frame_counter) * (std.time.ns_per_s / 60);
                if (self.shell) |sh| {
                    runner.advance(&sh.layout, w, h, sh.board, virtual_ns, self.frame_counter) catch {};
                }
            }
        }

        if (self.runner) |runner| {
            if (runner.poll()) |ev| return ev;
        }
        return self.inner.poll();
    }

    fn size(ctx: *anyopaque) Size {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.size();
    }

    fn scale(ctx: *anyopaque) f32 {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.scale();
    }

    fn present(ctx: *anyopaque, frame: *const Framebuffer) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        defer {
            self.frame_counter += 1;
            self.polled_this_frame = false;
        }

        if (self.writer) |writer| {
            const video_idx = @as(u32, @intCast(@divTrunc(@as(u64, self.frame_counter) * self.fps, 60)));
            if (self.last_video_frame == null or video_idx > self.last_video_frame.?) {
                self.last_video_frame = video_idx;
                const virtual_ns = @as(u64, self.frame_counter) * (std.time.ns_per_s / 60);

                if (self.show_cursor and self.runner != null) {
                    try self.ensureOverlay(frame.width, frame.height);
                    if (self.overlay_frame) |*of| {
                        @memcpy(of.pixels, frame.pixels);
                        const runner = self.runner.?;
                        cursor_mod.draw(of, runner.cursor_x, runner.cursor_y, runner.ripples.items, self.frame_counter);
                        try writer.record(of, virtual_ns);
                    }
                } else {
                    try writer.record(frame, virtual_ns);
                }
            }
        }

        return self.inner.present(frame);
    }

    fn ensureOverlay(self: *Capture, width: u32, height: u32) !void {
        if (self.overlay_frame) |of| {
            if (of.width == width and of.height == height) return;
            self.overlay_frame.?.deinit(self.allocator);
            self.overlay_frame = null;
        }
        self.overlay_frame = try Framebuffer.init(self.allocator, width, height);
    }

    fn show(ctx: *anyopaque, list: *const draw_list.DrawList, atlas: ?raster.Atlas) anyerror!bool {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.show(list, atlas);
    }

    fn interval(ctx: *anyopaque) u64 {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.interval();
    }

    fn setVsync(ctx: *anyopaque, on: bool) bool {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.setVsync(on);
    }

    fn refresh(ctx: *anyopaque) u32 {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.refresh();
    }

    fn appearance(ctx: *anyopaque) Appearance {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        return self.inner.appearance();
    }

    fn focus(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        self.inner.focus();
    }

    fn openImage(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        _ = self.inner.openImage();
    }

    fn openProfile(ctx: *anyopaque) void {
        const self: *Capture = @ptrCast(@alignCast(ctx));
        _ = self.inner.openProfile();
    }
};
