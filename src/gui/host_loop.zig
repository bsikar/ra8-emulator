//! The host shell's window loop (RA8EMU-646): each frame drains the
//! window's events into the panes, lets the camera follow its pane, runs
//! one slice of the emulation, then draws the board view and the panes and
//! presents them.
//!
//! It drives the run through `Run` and the window through the platform
//! seam, so the SDL window and the headless one run it the same way and a
//! test can step a short run and read back what it presented. The board is
//! the same composition `--frame-out` writes (board_view.zig), drawn at its
//! own size in the top-left corner with the camera pane to its right.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const raster = @import("raster.zig");
const platform = @import("platform.zig");
const camera_pane = @import("camera_pane.zig");
const camera_view = @import("camera_view.zig");
const FrameSource = @import("camera_switch.zig").FrameSource;
pub const board_view = @import("../interfaces/cli/board_view.zig");
const Color = draw_list.Color;

/// What the board shows right now: the panel's ARGB pixels and the LEDs.
pub const Board = struct {
    panel: []const u32,
    width: u32,
    height: u32,
    leds: []const board_view.Led,
};

/// Where the CEU reads its frames from, for the camera pane to swap.
pub const Camera = struct { source: *FrameSource, format_control: *const u8 };

/// The emulation the loop drives.
pub const Run = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Runs one frame's slice; false once the run has ended.
        step: *const fn (ctx: *anyopaque) bool,
        board: *const fn (ctx: *anyopaque) Board,
        /// Null when the board has no camera.
        camera: *const fn (ctx: *anyopaque) ?Camera,
    };
};

pub const background = camera_view.background;

/// ARGB8888 as an RGBA colour.
pub fn colorOf(argb: u32) Color {
    return .{ .r = @truncate(argb >> 16), .g = @truncate(argb >> 8), .b = @truncate(argb), .a = @truncate(argb >> 24) };
}

/// Where the camera pane sits beside a board view of `view`.
pub fn paneLayout(view: board_view.Size) camera_view.Layout {
    return .{ .x = @intCast(view.width + camera_view.gap), .y = @intCast(board_view.margin) };
}

pub const Loop = struct {
    allocator: std.mem.Allocator,
    pane: camera_pane.Pane = .{ .layout = .{ .x = 0, .y = 0 } },
    canvas: []u32 = &.{},
    pixels: []Color = &.{},
    frame: ?raster.Framebuffer = null,
    quit: bool = false,

    pub fn deinit(self: *Loop) void {
        self.allocator.free(self.canvas);
        self.allocator.free(self.pixels);
        if (self.frame) |*frame| frame.deinit(self.allocator);
    }

    /// One frame. Returns false once the run ended or the window closed;
    /// a closed window stops before the slice runs.
    pub fn tick(self: *Loop, window: platform.Platform, run: Run) !bool {
        const before = run.vtable.board(run.ctx);
        self.pane.layout = paneLayout(board_view.size(before.width, before.height));
        while (window.poll()) |event| {
            switch (event) {
                .quit => self.quit = true,
                else => _ = self.pane.handle(event),
            }
        }
        if (self.quit) return false;
        if (run.vtable.camera(run.ctx)) |camera| {
            self.pane.settle(self.allocator, camera.source, camera.format_control);
        }
        const running = run.vtable.step(run.ctx);
        try self.draw(window, run.vtable.board(run.ctx));
        return running;
    }

    fn draw(self: *Loop, window: platform.Platform, board: Board) !void {
        const view = board_view.size(board.width, board.height);
        try self.fitBoard(@as(usize, view.width) * view.height);
        board_view.compose(self.canvas, board.panel, board.width, board.height, board.leds);
        for (self.canvas, self.pixels) |argb, *pixel| pixel.* = colorOf(argb);
        const size = window.size();
        const frame = try self.fitFrame(size);
        var list = draw_list.DrawList.init(self.allocator, size.width, size.height);
        defer list.deinit();
        try list.fill(list.bounds, background);
        const area = draw_list.Rect{ .x = 0, .y = 0, .w = @intCast(view.width), .h = @intCast(view.height) };
        try list.image(area, .{ .width = view.width, .height = view.height, .pixels = self.pixels });
        try self.pane.draw(&list);
        raster.draw(frame, &list, null);
        try window.present(frame);
    }

    fn fitBoard(self: *Loop, count: usize) !void {
        if (self.canvas.len == count) return;
        self.allocator.free(self.canvas);
        self.allocator.free(self.pixels);
        self.canvas = &.{};
        self.pixels = &.{};
        self.canvas = try self.allocator.alloc(u32, count);
        self.pixels = try self.allocator.alloc(Color, count);
    }

    fn fitFrame(self: *Loop, size: platform.Size) !*raster.Framebuffer {
        if (self.frame) |*frame| {
            if (frame.width == size.width and frame.height == size.height) return frame;
            frame.deinit(self.allocator);
            self.frame = null;
        }
        self.frame = try raster.Framebuffer.init(self.allocator, size.width, size.height);
        return &self.frame.?;
    }
};
