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
const board_snapshot = @import("../../gui/board_snapshot.zig");
const window_pace = @import("window_pace.zig");
const SourceSwap = @import("../../gui/source_swap.zig").SourceSwap;
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
    /// What the window draws: the newest scan handed over (RA8EMU-227).
    handoff: board_snapshot.Handoff,
    /// The engine thread scans through parkHook, so a step only reads the
    /// handoff; otherwise the step scans after the slice itself.
    on_engine: bool = false,
    /// Camera picks the window opened, for the engine to install at a park.
    swap: SourceSwap = .{},

    pub fn init(allocator: std.mem.Allocator, board: *Board, stepper: Stepper) !Screen {
        var screen = Screen{ .allocator = allocator, .board = board, .stepper = stepper, .handoff = .init(allocator) };
        errdefer screen.deinit();
        try screen.publishScan();
        _ = screen.handoff.latest();
        return screen;
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.pixels);
        self.handoff.deinit();
        self.swap.deinit();
    }

    /// Scans and hands the result to the window.
    pub fn publishScan(self: *Screen) !void {
        try self.refresh();
        _ = try self.handoff.publish(.{ .panel = self.pixels, .width = self.width, .height = self.height, .leds = &self.leds });
    }

    /// For the pacer: on the engine thread at each park and at the end,
    /// install a waiting camera pick, then scan.
    pub fn parkHook(self: *Screen) window_pace.Hook {
        return .{ .ctx = self, .call = parkThunk };
    }

    fn parkThunk(ctx: *anyopaque) void {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        _ = self.swap.take(&self.board.capture.source);
        self.publishScan() catch {};
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

    /// The window looks at the panel; it is not a frame the guest made.
    /// Scanning bumps the report counters and raises VPOS, so the
    /// controller is put back exactly as it was afterwards (RA8EMU-656).
    /// It holds no heap state of its own, so the copy is the whole of it.
    fn scan(self: *Screen) bool {
        const unit = &self.board.display;
        const before = unit.*;
        defer unit.* = before;
        unit.output.capture = .{ .pixels = self.pixels, .width = self.width, .height = self.height };
        return unit.scanOut() != null;
    }

    pub fn run(self: *Screen) host_loop.Run {
        return .{ .ctx = self, .vtable = &.{ .step = step, .board = boardOf, .camera = camera } };
    }

    /// A slice, then the newest scan. When a scan cannot get memory for a
    /// resized panel the window keeps the last frame.
    fn step(ctx: *anyopaque) bool {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        const running = self.stepper.step(self.stepper.ctx);
        if (!self.on_engine) self.publishScan() catch {};
        _ = self.handoff.latest();
        return running;
    }

    fn boardOf(ctx: *anyopaque) host_loop.Board {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        return self.handoff.current();
    }

    fn camera(ctx: *anyopaque) ?host_loop.Camera {
        const self: *Screen = @ptrCast(@alignCast(ctx));
        const swap: ?*SourceSwap = if (self.on_engine) &self.swap else null;
        return .{ .source = &self.board.capture.source, .format_control = &self.board.wire.sensor.format, .swap = swap };
    }
};
