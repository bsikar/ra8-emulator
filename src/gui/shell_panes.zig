//! The shell's pane painter (RA8EMU-773): fills each leaf body of the shell
//! frame (RA8EMU-764) by the leaf's kind. The shell reaches its session only
//! over the link, and no pane has a feed there yet, so each body names the
//! feed it waits for; each feed replaces its note in its own change under
//! RA8EMU-772. The console leaf shows the console's log once it holds output
//! (RA8EMU-787), and the board leaf the panel image once a frame has arrived
//! (RA8EMU-790), and the devices leaf the fitted parts once the session has
//! listed them (RA8EMU-792), and the camera leaf its source picker
//! (RA8EMU-796); with a plug picker (RA8EMU-802) the devices leaf ends in
//! its field, and with a file field (RA8EMU-799) so does the camera leaf.
//! A registers leaf draws its bound core's registers once the session has
//! answered a read of them (RA8EMU-821).
//! An empty leaf stays blank.
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const pane_layout = @import("pane_layout.zig");
const shell_frame = @import("shell_frame.zig");
const console_pane = @import("console_pane.zig");
const shell_console = @import("shell_console.zig");
const shell_board = @import("shell_board.zig");
const shell_devices = @import("shell_devices.zig");
const shell_camera = @import("shell_camera.zig");
const shell_plug = @import("shell_plug.zig");
const shell_camera_file = @import("shell_camera_file.zig");
const shell_registers = @import("shell_registers.zig");
const registers_pane = @import("registers_pane.zig");

const Rect = draw_list.Rect;

/// The note a leaf of `kind` shows, or null when it draws nothing.
pub fn waitingFor(kind: pane_layout.Kind) ?[]const u8 {
    return switch (kind) {
        .empty => null,
        .board => "waiting for the board's frames",
        .camera => "waiting for the camera feed",
        .console => "waiting for console output",
        .devices => "waiting for the device list",
        .registers => "waiting for the registers",
    };
}

/// The feeds the panes draw from; a missing one leaves its note up.
pub const Panes = struct {
    console: ?*const shell_console.Console = null,
    board: ?*const shell_board.Board = null,
    devices: ?*const shell_devices.Devices = null,
    camera: ?*const shell_camera.Camera = null,
    plug: ?*shell_plug.Plug = null,
    camera_file: ?*shell_camera_file.CameraFile = null,
    registers: ?*const shell_registers.Pair = null,

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
        if (self.plug) |plug| if (devices.answered and !devices.refused) return shell_plug.draw(list, body, devices, plug);
        if (devices.answered and devices.note() == null) return shell_devices.draw(list, body, devices);
    };
    if (pane.kind == .camera) if (self.camera) |camera| {
        if (self.camera_file) |file| return shell_camera_file.draw(list, body, camera, file);
        return shell_camera.draw(list, body, camera);
    };
    if (pane.kind == .registers) if (self.registers) |pair| {
        const model = pair.of(pane.core);
        if (model.now) |now| return registers_pane.draw(list, body, now, model.before);
    };
    if (pane.kind == .board) if (self.board) |board| {
        if (board.hasFrame()) return list.image(shell_board.fitIn(body, board.width, board.height), board.image());
    };
    const note = noteFor(self, pane) orelse return;
    const at = noteAt(body) orelse return;
    try font.draw(list, at.x, at.y, font.fit(note, at.room), shell_frame.muted);
}

/// The note a leaf shows: the device list's or the registers' own once
/// they have answered.
fn noteFor(self: *const Panes, pane: pane_layout.Pane) ?[]const u8 {
    if (pane.kind == .devices) if (self.devices) |devices| {
        if (devices.note()) |note| return note;
    };
    if (pane.kind == .registers) if (self.registers) |pair| {
        if (pair.of(pane.core).note()) |note| return note;
    };
    return waitingFor(pane.kind);
}
