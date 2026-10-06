//! The shell loop (RA8EMU-763): one frame of the debugger shell. It drains
//! the window's events (quit, gutter drags), pumps the session link into the
//! status bar model, the console (RA8EMU-787) and the board (RA8EMU-790), then draws the shell frame (RA8EMU-764) and shows it
//! through the platform seam, so SDL and the headless platform run it alike.
const std = @import("std");
const draw_list = @import("draw_list.zig");
const raster = @import("raster.zig");
const font = @import("font.zig");
const platform = @import("platform.zig");
const pane_layout = @import("pane_layout.zig");
const shell_frame = @import("shell_frame.zig");
const status_bar = @import("status_bar.zig");
const session_link = @import("session_link.zig");
const shell_console = @import("shell_console.zig");
const shell_board = @import("shell_board.zig");

/// Most arrivals taken off the link in one frame, so a chatty session
/// cannot starve the window.
pub const max_arrivals: usize = 64;

pub const Shell = struct {
    allocator: std.mem.Allocator,
    layout: pane_layout.Layout,
    status: status_bar.Status = .{},
    link: ?*session_link.Link = null,
    painter: ?shell_frame.Painter = null,
    console: ?*shell_console.Console = null,
    board: ?*shell_board.Board = null,
    /// The splitter being dragged, from its button press to its release.
    held: ?pane_layout.Gutter = null,
    open: bool = true,
    frame: ?raster.Framebuffer = null,

    /// The shell owns `layout` from here on.
    pub fn init(allocator: std.mem.Allocator, layout: pane_layout.Layout) Shell {
        return .{ .allocator = allocator, .layout = layout };
    }

    pub fn deinit(self: *Shell) void {
        if (self.frame) |*frame| frame.deinit(self.allocator);
        self.layout.deinit();
    }

    /// The link's state, or closed when the shell has none.
    pub fn state(self: *const Shell) session_link.State {
        const link = self.link orelse return .closed;
        return link.state;
    }

    /// Run one frame. False once the window has asked to close.
    pub fn step(self: *Shell, window: platform.Platform) !bool {
        const size = window.size();
        const width: i32 = @intCast(size.width);
        const height: i32 = @intCast(size.height);
        var solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        defer solved.deinit(self.allocator);
        while (window.poll()) |event| self.handle(event, &solved);
        if (!self.open) return false;
        try self.pump();
        solved.deinit(self.allocator);
        solved = try shell_frame.solve(&self.layout, self.allocator, width, height);
        var list = draw_list.DrawList.init(self.allocator, size.width, size.height);
        defer list.deinit();
        try shell_frame.draw(&list, .{
            .layout = &self.layout,
            .solved = &solved,
            .status = &self.status,
            .state = self.state(),
            .width = width,
            .height = height,
            .painter = self.painter,
        });
        if (try window.show(&list, font.atlas)) return true;
        const frame = try self.fitFrame(size);
        raster.draw(frame, &list, font.atlas);
        try window.present(frame);
        return true;
    }

    /// Apply one input event against this frame's layout.
    pub fn handle(self: *Shell, event: platform.Event, solved: *const pane_layout.Solved) void {
        switch (event) {
            .quit => self.open = false,
            .button => |press| {
                if (press.button != 1) return;
                self.held = if (press.down) solved.hit(press.x, press.y) else null;
            },
            .pointer => |at| {
                const found = self.held orelse return;
                const axis = self.layout.node(found.split).body.split.axis;
                self.layout.drag(found, if (axis == .across) at.x else at.y);
            },
            else => {},
        }
    }

    /// Feed what the session sent into the status bar model, the console and the board.
    pub fn pump(self: *Shell) !void {
        const link = self.link orelse return;
        if (self.console) |console| console.attach(link);
        if (self.board) |board| board.attach(link);
        var taken: usize = 0;
        while (taken < max_arrivals) : (taken += 1) {
            const arrival = link.pump() orelse return;
            self.status.observe(link, arrival);
            if (self.console) |console| try console.observe(arrival);
            if (self.board) |board| try board.observe(arrival);
        }
    }

    fn fitFrame(self: *Shell, size: platform.Size) !*raster.Framebuffer {
        if (self.frame) |*frame| {
            if (frame.width == size.width and frame.height == size.height) return frame;
            frame.deinit(self.allocator);
            self.frame = null;
        }
        self.frame = try raster.Framebuffer.init(self.allocator, size.width, size.height);
        return &self.frame.?;
    }
};
