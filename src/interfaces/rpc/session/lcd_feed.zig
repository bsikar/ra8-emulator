//! LCD dirty rectangles for subscribed clients (RA8EMU-789). The session
//! event stream carries one lcd_frame event per panel refresh, naming the
//! rectangle that changed. This drains its own queue, keeps the bounding
//! box of each core's rectangles, captures the panel once and sends each
//! box's grayscale pixels as lcd_dirty events, split by rows so no event
//! carries more than DirtyRect's pixel cap. The stream coalesces queued
//! frames per core, so after a drop the whole panel goes out instead. A
//! subscriber can ask for a frames-per-second rate (RA8EMU-822): between
//! sends its rectangles are merged into one bounding box of the latest
//! frame and the panel is not captured until the rate's next send falls
//! due, so a rate nobody meets costs no conversion. The server supplies the
//! host clock through its context; without one a rate sends every pass.
const std = @import("std");
const proto = @import("rpc.zig");
const api = @import("ra8_session").api;
const Context = @import("handlers.zig").Context;

/// Events read from the stream per pass.
const batch = 32;
/// The most pixel bytes one lcd_dirty event carries.
pub const max_pixels: usize = proto.DirtyRect.max_len.pixels;

const Rect = api.Event.Rect;
const Due = @import("handlers.zig").LcdDue;

/// Send the pixels of every panel change a subscribed core saw through `server`.
pub fn pump(context: *Context, server: anytype, tx: []u8) !void {
    const id = context.lcd_feed orelse return;
    var due: [2]?Due = .{ null, null };
    var whole = false;
    var events: [batch]api.Event = undefined;
    while (context.session.pollEvents(id, &events)) |read| {
        if (read.dropped != 0) whole = true;
        for (events[0..read.count]) |event| note(context, &due, event);
        if (read.count < batch) break;
    }
    // A rate-limited subscriber holds its rectangles merged between sends
    // (RA8EMU-822); a due one takes them, and a dropped stream sends whole.
    const now_ns = hostNow(context);
    for (due, 0..) |fresh, index| {
        const slot = &context.lcd_pending[index];
        if (fresh) |f| slot.* = if (slot.*) |held|
            .{ .rect = merge(held.rect, f.rect), .virtual_ns = f.virtual_ns }
        else
            f;
        const held = slot.* orelse continue;
        const limited = context.host_clock != null and context.lcd_rate[index] != 0;
        if (whole or !limited or now_ns >= context.lcd_last_ns[index] + interval(context.lcd_rate[index])) {
            due[index] = held;
            slot.* = null;
        } else {
            context.lcd_holds += 1;
            due[index] = null;
        }
    }
    if (due[0] == null and due[1] == null) return;
    const gpa = context.gpa orelse return;
    var frame = context.session.frame(gpa) catch |err| return skip("capture", err);
    defer frame.deinit(gpa);
    if (frame.pixels.len != @as(usize, frame.width) * frame.height) return skip("capture", error.BadFrameShape);
    const chunk = gpa.alloc(u8, max_pixels) catch |err| return skip("buffer", err);
    defer gpa.free(chunk);
    for (due, 0..) |pending, index| {
        const held = pending orelse continue;
        const rect = clip(if (whole) full(frame) else held.rect, frame);
        if (rect.width == 0 or rect.height == 0) continue;
        try send(server, @fromBackingInt(@intCast(index)), rect, held.virtual_ns, frame, chunk, tx);
        context.lcd_last_ns[index] = now_ns;
    }
}

/// The host clock in nanoseconds, through the context's clock hook (RA8EMU-822).
fn hostNow(context: *const Context) u64 {
    const clock = context.host_clock orelse return 0;
    return clock.nowFn(clock.context);
}

/// The host interval between sends at `rate` frames per second; 0 sends every pass.
fn interval(rate: u16) u64 {
    if (rate == 0) return 0;
    return (@as(u64, std.time.ns_per_s) + rate - 1) / rate;
}

fn skip(what: []const u8, err: anyerror) void {
    std.debug.print("serve: lcd {s} failed: {s}\n", .{ what, @errorName(err) });
}

fn note(context: *const Context, due: *[2]?Due, event: api.Event) void {
    if (event.kind != .lcd_frame) return;
    const frame = switch (event.payload) {
        .frame => |refreshed| refreshed,
        else => return,
    };
    const of: proto.Core = @fromBackingInt(@intCast(@backingInt(event.core)));
    if (!context.wants(of, .lcd_dirty)) return;
    const slot = &due[@backingInt(of)];
    const rect = if (slot.*) |held| merge(held.rect, frame.dirty) else frame.dirty;
    slot.* = .{ .rect = rect, .virtual_ns = event.virtual_ns };
}

/// The smallest rectangle holding both.
pub fn merge(a: Rect, b: Rect) Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(@as(u32, a.x) + a.width, @as(u32, b.x) + b.width);
    const bottom = @max(@as(u32, a.y) + a.height, @as(u32, b.y) + b.height);
    return .{ .x = left, .y = top, .width = narrow(right - left), .height = narrow(bottom - top) };
}

fn full(frame: api.Frame) Rect {
    return .{ .x = 0, .y = 0, .width = narrow(frame.width), .height = narrow(frame.height) };
}

/// `rect` cut to the panel; empty when it lies outside.
pub fn clip(rect: Rect, frame: api.Frame) Rect {
    const width = narrow(frame.width);
    const height = narrow(frame.height);
    const x = @min(rect.x, width);
    const y = @min(rect.y, height);
    return .{ .x = x, .y = y, .width = @min(rect.width, width - x), .height = @min(rect.height, height - y) };
}

fn narrow(value: u32) u16 {
    return @intCast(@min(value, std.math.maxInt(u16)));
}

pub fn send(server: anytype, of: proto.Core, rect: Rect, virtual_ns: u64, frame: api.Frame, chunk: []u8, tx: []u8) !void {
    const rows_per: u16 = @intCast(@min(rect.height, max_pixels / rect.width));
    var row: u16 = 0;
    while (row < rect.height) : (row += rows_per) {
        const rows = @min(rows_per, rect.height - row);
        for (0..rows) |r| {
            const from = (@as(usize, rect.y) + row + r) * frame.width + rect.x;
            @memcpy(chunk[r * rect.width ..][0..rect.width], frame.pixels[from..][0..rect.width]);
        }
        const event: proto.DirtyRect = .{
            .core = of,
            .x = rect.x,
            .y = rect.y + row,
            .width = rect.width,
            .height = rows,
            .virtual_ns = virtual_ns,
            .pixels = chunk[0 .. @as(usize, rows) * rect.width],
        };
        try server.emit(proto.DirtyRect, @backingInt(proto.Topic.lcd_dirty), event, tx);
    }
}
