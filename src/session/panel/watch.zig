//! A viewer's watch on the GLCDC panel (RA8EMU-1126). The GLCDC model
//! composites a frame only when something scans it (glcdc/vsync.zig), so a
//! client subscribed to the panel would never hear of one. While a viewer
//! watches, this arms the panel's frame boundary the way `--frames-out`
//! does: at each boundary it scans the panel into its own buffer, and when
//! the picture differs from the one before, it keeps it and tells the
//! session's event sources what changed. A picture that holds still is
//! scanned and says nothing.
//!
//! The scan is the watch's own, so the model's frame hook is held off while
//! it runs and the event carries the changed box instead of the whole
//! panel. With the last viewer gone the boundary comes off again, and a
//! session nobody watches runs exactly as it did: an in-run scan raises VPOS
//! for the firmware, which is why the model leaves it to a viewer to ask.
//! An e-ink panel reports its own refreshes and needs none of this.
const std = @import("std");
const Board = @import("ra8_board").board.Board;
const Sources = @import("../event/sources.zig").Sources;
const session_display = @import("../display.zig");
const panel_diff = @import("diff.zig");
const frame_tap = @import("ra8_board").frame_tap;

pub const Watch = struct {
    allocator: std.mem.Allocator,
    board: *Board,
    /// Where a changed picture is published. Without one the watch only
    /// keeps the picture.
    events: ?*Sources = null,
    /// Viewers watching. The frame boundary is armed while there is one.
    viewers: u32 = 0,
    /// The picture the panel last showed, and the buffer the next scan
    /// lands in.
    kept: []u32 = &.{},
    scratch: []u32 = &.{},
    /// The kept picture's shape; zero until a scan has landed.
    width: u32 = 0,
    height: u32 = 0,
    /// Board time of the scan that last changed the picture.
    changed_ns: u64 = 0,
    /// The passive per-boundary capture (the frame tap), ridden when the
    /// run's panel_vsync config has armed no frame edges to attach to.
    tap: frame_tap.Tap = undefined,
    /// True once useIo built the tap; until then the watch cannot capture.
    tapped: bool = false,

    pub fn deinit(self: *Watch) void {
        self.disarm();
        self.drop();
    }

    /// Build the tap with the io it rate-caps itself against. Call once,
    /// before the first viewer arrives.
    pub fn useIo(self: *Watch, io: std.Io) void {
        self.tap = .{ .io = io, .context = self, .captureFn = onFrame };
        self.tapped = true;
    }

    /// One viewer more, or one fewer.
    pub fn set(self: *Watch, on: bool) void {
        if (on) {
            self.viewers += 1;
            if (self.viewers == 1) self.arm();
            return;
        }
        if (self.viewers == 0) return;
        self.viewers -= 1;
        if (self.viewers != 0) return;
        self.disarm();
        self.drop();
    }

    /// The kept picture as an owned grayscale frame, or null when nobody
    /// watches or no scan has landed yet.
    pub fn picture(self: *const Watch, allocator: std.mem.Allocator) !?session_display.Frame {
        if (self.viewers == 0 or self.width == 0) return null;
        const pixels = try allocator.alloc(u8, self.kept.len);
        for (self.kept, pixels) |argb, *gray| gray.* = session_display.grayscale(argb);
        return .{ .width = self.width, .height = self.height, .pixels = pixels, .virtual_ns = self.changed_ns };
    }

    /// Arm the frame boundary from the next board boundary on, unless a
    /// viewer of another kind already scans the panel.
    fn arm(self: *Watch) void {
        const stage = &self.board.display.output;
        // The frame clock is the run's panel_vsync config; a viewer attaches
        // to it and never arms or resizes it (RA8EMU R9).
        if (stage.vsync) |*clock| {
            if (clock.sink == null) clock.sink = .{ .context = self, .frame = onFrame };
            return;
        }
        if (self.tapped) self.board.addFrameTap(&self.tap);
    }

    fn disarm(self: *Watch) void {
        const stage = &self.board.display.output;
        if (stage.vsync) |*clock| {
            if (clock.sink) |sink| if (sink.frame == onFrame and sink.context == @as(*anyopaque, self)) {
                clock.sink = null;
            };
        }
        self.board.removeFrameTap(&self.tap);
    }

    fn drop(self: *Watch) void {
        self.allocator.free(self.kept);
        self.allocator.free(self.scratch);
        self.kept = &.{};
        self.scratch = &.{};
        self.width = 0;
        self.height = 0;
    }

    fn onFrame(context: *anyopaque, when_ns: u64) void {
        const self: *Watch = @ptrCast(@alignCast(context));
        self.scan(when_ns) catch |err| std.debug.print("session: the panel watch lost a frame: {s}\n", .{@errorName(err)});
    }

    /// Scan the panel as the firmware has it now, and publish what changed.
    fn scan(self: *Watch, when_ns: u64) !void {
        const display = &self.board.display;
        const width = display.panelWidth();
        const height = display.panelHeight();
        if (width == 0 or height == 0) return;
        const count = try std.math.mul(usize, width, height);
        if (self.scratch.len != count) {
            self.allocator.free(self.scratch);
            self.scratch = &.{};
            self.scratch = try self.allocator.alloc(u32, count);
        }
        // The picture comes from the pure composite: the scan raises VPOS
        // and counts frames, and a watch is never one more frame for the
        // firmware (RA8EMU R9).
        const source = display.compositeInputs() orelse return;
        switch (display.composite(source, display.domain.powered(), self.scratch)) {
            .picture => {},
            .refused => return,
        }
        const dirty = self.take(width, height) orelse return;
        self.changed_ns = when_ns;
        if (self.events) |events| events.panelChanged(width, height, display.system.frames, dirty);
    }

    /// Make the scanned buffer the kept picture and return what changed:
    /// the whole panel for a first picture or a new shape, null when it is
    /// the picture already kept.
    fn take(self: *Watch, width: u32, height: u32) ?panel_diff.Rect {
        const same_shape = self.width == width and self.height == height;
        const dirty = if (same_shape) panel_diff.box(self.kept, self.scratch, width) orelse return null else panel_diff.whole(width, height);
        std.mem.swap([]u32, &self.kept, &self.scratch);
        self.width = width;
        self.height = height;
        return dirty;
    }
};
