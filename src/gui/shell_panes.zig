//! The shell's pane painter (RA8EMU-773): fills each leaf body of the shell
//! frame (RA8EMU-764) by the leaf's kind. The shell reaches its session only
//! over the link, and no pane has a feed there yet, so each body names the
//! feed it waits for; each feed replaces its note in its own change under
//! RA8EMU-772. The console leaf shows the console's log once it holds output
//! (RA8EMU-787), and the board leaf the panel image once a frame has arrived
//! (RA8EMU-790), and the devices leaf the fitted parts once the session has
//! listed them (RA8EMU-792). An empty leaf stays blank.
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const pane_layout = @import("pane_layout.zig");
const shell_frame = @import("shell_frame.zig");
const console_pane = @import("console_pane.zig");
const shell_console = @import("shell_console.zig");
const shell_board = @import("shell_board.zig");
const shell_devices = @import("shell_devices.zig");

const Rect = draw_list.Rect;

/// The note a leaf of `kind` shows, or null when it draws nothing.
pub fn waitingFor(kind: pane_layout.Kind) ?[]const u8 {
    return switch (kind) {
        .empty => null,
        .board => "waiting for the board's frames",
        .camera => "waiting for the camera feed",
        .console => "waiting for console output",
        .devices => "waiting for the device list",
    };
}

/// The feeds the panes draw from; a missing one leaves its note up.
pub const Panes = struct {
    console: ?*const shell_console.Console = null,
    board: ?*const shell_board.Board = null,
    devices: ?*const shell_devices.Devices = null,

    pub fn painter(self: *Panes) shell_frame.Painter {
        return .{ .context = self, .paint = paint };
    }
};

/// Where the note's text starts in `body`: inset by the frame's pad and
/// centred down the body. Null when the body cannot hold one row.
pub fn noteAt(body: Rect) ?struct { x: i32, y: i32, room: u32 } {
    const room = body.w - 2 * shell_frame.pad;
    const glyph: i32 = font.glyph_h;
    if (room <= 0 or body.h < glyph) return null;
    return .{ .x = body.x + shell_frame.pad, .y = body.y + @divTrunc(body.h - glyph, 2), .room = @intCast(room) };
}

fn paint(context: *anyopaque, list: *draw_list.DrawList, pane: pane_layout.Pane, body: Rect) anyerror!void {
    const self: *Panes = @ptrCast(@alignCast(context));
    if (pane.kind == .console) if (self.console) |console| {
        if (console.hasOutput()) return console_pane.draw(list, body, &console.log, 0);
    };
    if (pane.kind == .devices) if (self.devices) |devices| {
        if (devices.answered and devices.note() == null) return shell_devices.draw(list, body, devices);
    };
    if (pane.kind == .board) if (self.board) |board| {
        if (board.hasFrame()) return list.image(shell_board.fitIn(body, board.width, board.height), board.image());
    };
    const note = noteFor(self, pane.kind) orelse return;
    const at = noteAt(body) orelse return;
    try font.draw(list, at.x, at.y, font.fit(note, at.room), shell_frame.muted);
}

/// The note a leaf shows: the device list's own once it has answered.
fn noteFor(self: *const Panes, kind: pane_layout.Kind) ?[]const u8 {
    if (kind == .devices) if (self.devices) |devices| {
        if (devices.note()) |note| return note;
    };
    return waitingFor(kind);
}
