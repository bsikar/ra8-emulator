//! The frame a held reverse play shows, sent to the LCD subscribers the way
//! a live panel change is: as full-panel `lcd_dirty` rectangles of
//! grayscale pixels, so a client that draws the live panel draws the rewind
//! with no separate path. Only a frame not yet sent goes out, and only
//! while the engine is playing backward.
const std = @import("std");
const api = @import("ra8_session").api;
const proto = @import("rpc.zig");
const lcd_feed = @import("lcd_feed.zig");
const Context = @import("handlers.zig").Context;

/// Sends the rewind frame the engine shows, if it is new to this connection.
pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    const rewind = context.session.smooth_rewind orelse return;
    if (!rewind.isBusy()) {
        context.nav.rewind_sent = null;
        return;
    }
    const shown = rewind.current_frame orelse return;
    if (context.nav.rewind_sent) |last| {
        if (std.meta.eql(last, shown.position)) return;
    }
    if (!context.wants(.cpu0, .lcd_dirty)) return;
    const gpa = context.gpa orelse return;
    const frame: api.Frame = .{ .width = shown.width, .height = shown.height, .pixels = shown.pixels, .virtual_ns = shown.virtual_ns };
    const chunk = gpa.alloc(u8, lcd_feed.max_pixels) catch return;
    defer gpa.free(chunk);
    const rect: api.Event.Rect = .{ .x = 0, .y = 0, .width = shown.width, .height = shown.height };
    try lcd_feed.send(server, .cpu0, lcd_feed.clip(rect, frame), shown.virtual_ns, frame, chunk, tx);
    context.nav.rewind_sent = shown.position;
}
