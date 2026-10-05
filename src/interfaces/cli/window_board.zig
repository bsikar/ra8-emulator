//! The real board as the host window's `Run` (RA8EMU-646): after each
//! slice it scans the GLCDC the way `--frame-out` does and reads the user
//! LEDs, so the window shows the same board view the PNG would, and it
//! hands the camera pane the CEU's source and the sensor's format register.
//!
//! The slice itself comes from a `Stepper`, so the window never reaches
//! into an engine: the run mode wraps whichever backend is running.
const std = @import("std");
const Board = @import("../../board/board.zig").Board;
const gpio = @import("../../periph/gpio/gpio.zig");
const frame_out = @import("frame_out.zig");
const host_loop = @import("../../gui/host_loop.zig");
const board_view = frame_out.board_view;

/// Runs one frame's slice of emulated time; false once the run has ended.
pub const Stepper = struct {
    ctx: *anyopaque,
    step: *const fn (ctx: *anyopaque) bool,
};

pub const Screen = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    stepper: Stepper,
    pixels: []u32 = &.{},
    width: u32 = board_view.panel_width,
    height: u32 = board_view.panel_height,
    leds: [gpio.led_count]board_view.Led = undefined,
    /// Whether the last scan gave a frame; without one the panel is dark.
    frame: bool = false,

    pub fn init(allocator: std.mem.Allocator, board: *Board, stepper: Stepper) !Screen {
        var screen = Screen{ .allocator = allocator, .board = board, .stepper = stepper };
        try screen.refresh();
        return screen;
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.pixels);
    }

    /// Scans the panel and reads the LEDs. The panel goes out opaque, as
    /// the PNG does: what reaches the glass has no transparency.
    pub fn refresh(self: *Screen) !void {
        const unit = &self.board.display;
        const scanned = unit.panelWidth() != 0 and unit.panelHeight() != 0;
        const width = if (scanned) unit.panelWidth() else board_view.panel_width;
        const height = if (scanned) unit.panelHeight() else board_view.panel_height;
        const count = @as(usize, width) * height;
        if (self.pixels.len != count) {
            self.allocator.free(self.pixels);
            self.pixels = &.{};
            self.pixels = try self.allocator.alloc(u32, count);
        }
        self.width = width;
        self.height = height;
        @memset(self.pixels, 0);
        self.frame = scanned and self.scan();
        if (!self.frame) @memset(self.pixels, 0);
        for (self.pixels) |*pixel| pixel.* |= 0xFF000000;
        self.leds = frame_out.ledsOf(self.board);
    }

    fn scan(self: *Screen) bool {
        const unit = &self.board.display;
        unit.output.capture = .{ .pixels = self.pixels, .width = self.width, .height = self.height };
        defer unit.output.capture = null;
        return unit.scanOut() != null;
    }

    pub fn run(self: *Screen) host_loop.Run {
        return .{ .ctx = self, .vtable = &.{ .step = step, .board = boardOf, .camera = camera } };
    }

    /// A slice, then a fresh scan. When the scan cannot get memory for a
    /// resized panel the window keeps the last frame.
    fn step(ctx: *anyopaque) bool {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        const running = self.stepper.step(self.stepper.ctx);
        self.refresh() catch {};
        return running;
    }

    fn boardOf(ctx: *anyopaque) host_loop.Board {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        return .{ .panel = self.pixels, .width = self.width, .height = self.height, .leds = &self.leds };
    }

    fn camera(ctx: *anyopaque) ?host_loop.Camera {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        return .{ .source = &self.board.capture.source, .format_control = &self.board.wire.sensor.format };
    }
};
