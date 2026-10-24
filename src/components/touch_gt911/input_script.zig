//! Timed host input events, dispatched on the board's virtual clock.
const std = @import("std");
const host = @import("touch_input.zig");
const gt911 = @import("gt911.zig");
const gpio = @import("ra8_chip").periph.gpio;
pub const Event = union(enum) {
    tap: gt911.Contact,
    swipe: struct { from: gt911.Contact, to: gt911.Contact, duration_ns: u64 },
    longpress: struct { point: gt911.Contact, duration_ns: u64 },
    button: struct { down: bool, button_id: Button },
};
/// The event's own bytes for the history recorder (slice 16): one tag
/// byte, then the fields little-endian. The event's detail stays with the
/// subsystem that emitted it; the recorder just carries it.
pub const max_body_len: usize = 17;

pub fn encodeBody(writer: anytype, event: Event) !void {
    switch (event) {
        .tap => |contact| {
            try writer.writeByte(1);
            try writer.writeInt(u16, contact.x, .little);
            try writer.writeInt(u16, contact.y, .little);
        },
        .swipe => |move| {
            try writer.writeByte(2);
            try writer.writeInt(u16, move.from.x, .little);
            try writer.writeInt(u16, move.from.y, .little);
            try writer.writeInt(u16, move.to.x, .little);
            try writer.writeInt(u16, move.to.y, .little);
            try writer.writeInt(u64, move.duration_ns, .little);
        },
        .longpress => |hold| {
            try writer.writeByte(3);
            try writer.writeInt(u16, hold.point.x, .little);
            try writer.writeInt(u16, hold.point.y, .little);
            try writer.writeInt(u64, hold.duration_ns, .little);
        },
        .button => |press| {
            try writer.writeByte(4);
            try writer.writeByte(@intFromBool(press.down));
            try writer.writeByte(@backingInt(press.button_id));
        },
    }
}

pub fn decodeBody(body: []const u8) !Event {
    if (body.len == 0) return error.Truncated;
    switch (body[0]) {
        1 => {
            if (body.len < 5) return error.Truncated;
            const x = std.mem.readInt(u16, body[1..3], .little);
            const y = std.mem.readInt(u16, body[3..5], .little);
            return .{ .tap = .{ .x = x, .y = y } };
        },
        2 => {
            if (body.len < 17) return error.Truncated;
            const fx = std.mem.readInt(u16, body[1..3], .little);
            const fy = std.mem.readInt(u16, body[3..5], .little);
            const tx = std.mem.readInt(u16, body[5..7], .little);
            const ty = std.mem.readInt(u16, body[7..9], .little);
            const dur = std.mem.readInt(u64, body[9..17], .little);
            return .{ .swipe = .{ .from = .{ .x = fx, .y = fy }, .to = .{ .x = tx, .y = ty }, .duration_ns = dur } };
        },
        3 => {
            if (body.len < 13) return error.Truncated;
            const x = std.mem.readInt(u16, body[1..3], .little);
            const y = std.mem.readInt(u16, body[3..5], .little);
            const dur = std.mem.readInt(u64, body[5..13], .little);
            return .{ .longpress = .{ .point = .{ .x = x, .y = y }, .duration_ns = dur } };
        },
        4 => {
            if (body.len < 3) return error.Truncated;
            const down = body[1] != 0;
            const btn: Button = if (body[2] == 0) .sw1 else .sw2;
            return .{ .button = .{ .down = down, .button_id = btn } };
        },
        else => return error.BadValue,
    }
}

pub const Timed = struct { at_ns: u64, event: Event };
pub const max_events = 256;
pub const Button = enum { sw1, sw2 };
const Active = union(enum) {
    swipe: struct { from: gt911.Contact, to: gt911.Contact, start: u64, duration: u64, next: u64 },
    longpress: struct { point: gt911.Contact, start: u64, duration: u64, next: u64 },
};
pub const Script = struct {
    events: [max_events]Timed = undefined,
    len: usize = 0,
    cursor: usize = 0,
    previous_at: u64 = 0,
    active: ?Active = null,
    button_release: ?struct { at_ns: u64, button_id: Button } = null,
    now_ns: u64 = 0,
    pub fn parse(self: *Script, text: []const u8) !void {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (self.len == max_events) return error.TooManyEvents;
            const timed = try parseLine(line);
            if (self.len > 0 and timed.at_ns < self.previous_at) return error.OutOfOrder;
            self.previous_at = timed.at_ns;
            self.events[self.len] = timed;
            self.len += 1;
        }
    }
    /// Schedule one typed event on the same virtual-time queue as a script.
    /// Pending events stay ordered; equal-time events retain insertion order.
    pub fn schedule(self: *Script, timed: Timed) !void {
        if (timed.at_ns < self.now_ns) return error.InputInPast;
        if (self.len == max_events) return error.TooManyEvents;
        var position = self.cursor;
        while (position < self.len and self.events[position].at_ns <= timed.at_ns) : (position += 1) {}
        var end = self.len;
        while (end > position) : (end -= 1) self.events[end] = self.events[end - 1];
        self.events[position] = timed;
        self.len += 1;
        self.previous_at = @max(self.previous_at, timed.at_ns);
    }

    /// The virtual time of the next thing `dispatch` would do: a queued
    /// event, a held button's release, or a gesture's next frame. Null when
    /// nothing is left, so a run may go as wide as its other edges allow
    /// (RA8EMU-1120).
    pub fn nextDue(self: *const Script) ?u64 {
        var due: ?u64 = null;
        if (self.cursor < self.len) due = self.events[self.cursor].at_ns;
        if (self.button_release) |release| due = earlier(due, release.at_ns);
        if (self.active) |active| due = earlier(due, switch (active) {
            .swipe => |swipe| swipe.next,
            .longpress => |press| press.next,
        });
        return due;
    }

    /// The landing observer (slice 16): called once per queued event as it
    /// applies, with the event and its own scheduled time. Gesture frames
    /// the event generates later stay derived: the queued event replays them.
    pub const Landing = struct {
        context: *anyopaque,
        notify: *const fn (context: *anyopaque, event: Event, at_ns: u64) void,
    };

    pub fn dispatch(self: *Script, now_ns: u64, panel: *gt911.Panel, pins: *gpio.Gpio, input: *host.Input) void {
        return self.dispatchObserved(now_ns, panel, pins, input, null);
    }

    pub fn dispatchObserved(self: *Script, now_ns: u64, panel: *gt911.Panel, pins: *gpio.Gpio, input: *host.Input, observer: ?*const Landing) void {
        // Script times are absolute virtual board time, as the doc says:
        // "at 2s" is 2 s after reset, wherever the first boundary lands.
        const elapsed = now_ns;
        self.now_ns = @max(self.now_ns, elapsed);
        if (self.button_release) |release| if (elapsed >= release.at_ns) {
            input.feedLine(panel, pins, switchLine(release.button_id, false));
            self.button_release = null;
        };
        while (self.cursor < self.len and self.events[self.cursor].at_ns <= elapsed) : (self.cursor += 1) {
            const timed = self.events[self.cursor];
            if (observer) |observed| observed.notify(observed.context, timed.event, timed.at_ns);
            switch (timed.event) {
                .tap => |point| panel.queue(point) catch {
                    input.refused += 1;
                },
                .longpress => |press| {
                    self.active = .{ .longpress = .{ .point = press.point, .start = timed.at_ns, .duration = press.duration_ns, .next = timed.at_ns + frame_ns } };
                    panel.queue(press.point) catch {
                        input.refused += 1;
                    };
                },
                .swipe => |swipe| {
                    self.active = .{ .swipe = .{ .from = swipe.from, .to = swipe.to, .start = timed.at_ns, .duration = swipe.duration_ns, .next = timed.at_ns + frame_ns } };
                    panel.queue(swipe.from) catch {
                        input.refused += 1;
                    };
                },
                .button => |button| {
                    input.feedLine(panel, pins, switchLine(button.button_id, button.down));
                    if (button.down) self.button_release = .{ .at_ns = timed.at_ns + button_press_ns, .button_id = button.button_id };
                },
            }
        }
        if (self.active) |*active| switch (active.*) {
            .swipe => |*swipe| if (elapsed >= swipe.next) {
                const passed = @min(elapsed - swipe.start, swipe.duration);
                const point = interpolate(swipe.from, swipe.to, passed, swipe.duration);
                panel.queue(point) catch {
                    input.refused += 1;
                };
                if (passed == swipe.duration) self.active = null else swipe.next += frame_ns;
            },
            .longpress => |*press| if (elapsed >= press.next) {
                if (elapsed - press.start >= press.duration) {
                    self.active = null;
                } else {
                    panel.queue(press.point) catch {
                        input.refused += 1;
                    };
                    press.next += frame_ns;
                }
            },
        };
    }
};
const frame_ns: u64 = 50_000_000;
fn earlier(due: ?u64, at: u64) u64 {
    return if (due) |known| @min(known, at) else at;
}
fn switchLine(which: Button, down: bool) []const u8 {
    return switch (which) {
        .sw1 => if (down) "sw1 down" else "sw1 up",
        .sw2 => if (down) "sw2 down" else "sw2 up",
    };
}
const button_press_ns: u64 = 100_000_000;
fn interpolate(from: gt911.Contact, to: gt911.Contact, elapsed: u64, duration_ns: u64) gt911.Contact {
    if (duration_ns == 0) return to;
    const x = @as(i64, from.x) + @divTrunc((@as(i64, to.x) - from.x) * @as(i64, @intCast(elapsed)), @as(i64, @intCast(duration_ns)));
    const y = @as(i64, from.y) + @divTrunc((@as(i64, to.y) - from.y) * @as(i64, @intCast(elapsed)), @as(i64, @intCast(duration_ns)));
    return .{ .x = @intCast(x), .y = @intCast(y) };
}
fn parseLine(line: []const u8) !Timed {
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, words.next() orelse return error.InvalidScript, "at")) return error.InvalidScript;
    const at = try duration(words.next() orelse return error.InvalidScript);
    const verb = words.next() orelse return error.InvalidScript;
    var result: Event = undefined;
    if (std.mem.eql(u8, verb, "tap")) {
        result = .{ .tap = .{ .x = try number(words.next()), .y = try number(words.next()) } };
    } else if (std.mem.eql(u8, verb, "swipe")) {
        result = .{ .swipe = .{ .from = .{ .x = try number(words.next()), .y = try number(words.next()) }, .to = .{ .x = try number(words.next()), .y = try number(words.next()) }, .duration_ns = try duration(words.next() orelse return error.InvalidScript) } };
    } else if (std.mem.eql(u8, verb, "longpress")) {
        result = .{ .longpress = .{ .point = .{ .x = try number(words.next()), .y = try number(words.next()) }, .duration_ns = try duration(words.next() orelse return error.InvalidScript) } };
    } else if (std.mem.eql(u8, verb, "button")) {
        const name = words.next() orelse return error.InvalidScript;
        if (std.mem.eql(u8, name, "power") or std.mem.eql(u8, name, "sw1")) {
            result = .{ .button = .{ .down = true, .button_id = .sw1 } };
        } else if (std.mem.eql(u8, name, "sw2")) {
            result = .{ .button = .{ .down = true, .button_id = .sw2 } };
        } else return error.InvalidScript;
    } else return error.InvalidScript;
    if (words.next() != null) return error.InvalidScript;
    return .{ .at_ns = at, .event = result };
}
fn number(token: ?[]const u8) !u16 {
    return std.fmt.parseInt(u16, token orelse return error.InvalidScript, 10);
}
fn duration(token: []const u8) !u64 {
    const ms = std.mem.endsWith(u8, token, "ms");
    const seconds = std.mem.endsWith(u8, token, "s") and !ms;
    if (!ms and !seconds) return error.InvalidScript;
    const digits = token[0 .. token.len - if (ms) @as(usize, 2) else 1];
    return std.math.mul(u64, try std.fmt.parseInt(u64, digits, 10), if (ms) 1_000_000 else 1_000_000_000) catch error.InvalidScript;
}
