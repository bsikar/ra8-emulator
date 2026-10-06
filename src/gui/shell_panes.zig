//! The shell's pane painter (RA8EMU-773): fills each leaf body of the shell
//! frame (RA8EMU-764) by the leaf's kind. The shell reaches its session only
//! over the link, and no pane has a feed there yet, so each body names the
//! feed it waits for; each feed replaces its note in its own change under
//! RA8EMU-772. An empty leaf stays blank.
const draw_list = @import("draw_list.zig");
const font = @import("font.zig");
const pane_layout = @import("pane_layout.zig");
const shell_frame = @import("shell_frame.zig");

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

/// The painter needs no state of its own; the frame wants a context anyway.
var stateless: u8 = 0;

pub fn painter() shell_frame.Painter {
    return .{ .context = &stateless, .paint = paint };
}

/// Where the note's text starts in `body`: inset by the frame's pad and
/// centred down the body. Null when the body cannot hold one row.
pub fn noteAt(body: Rect) ?struct { x: i32, y: i32, room: u32 } {
    const room = body.w - 2 * shell_frame.pad;
    const glyph: i32 = font.glyph_h;
    if (room <= 0 or body.h < glyph) return null;
    return .{ .x = body.x + shell_frame.pad, .y = body.y + @divTrunc(body.h - glyph, 2), .room = @intCast(room) };
}

fn paint(context: *anyopaque, list: *draw_list.DrawList, pane: pane_layout.Pane, body: Rect) anyerror!void {
    _ = context;
    const note = waitingFor(pane.kind) orelse return;
    const at = noteAt(body) orelse return;
    try font.draw(list, at.x, at.y, font.fit(note, at.room), shell_frame.muted);
}
