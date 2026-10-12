//! The shell's board feed (RA8EMU-790, RA8EMU-1119): the panel image the
//! session streams as lcd_dirty rectangles of grayscale pixels (RA8EMU-789),
//! and the user LEDs it reports as led_changed events on the session topic
//! (RA8EMU-811), and asks the session for the board's front-panel parts
//! (RA8EMU-1151), which the pane lays out and lights. Once the link is
//! connected it subscribes both cores and asks once for the board parts.
//! Each rectangle is copied into an RGBA image that grows to cover every
//! rectangle seen, and pixels no rectangle has reached yet stay black. The
//! LEDs need no panel, so an image with no LCD output still shows them.
const std = @import("std");
const proto = @import("ra8_rpc").session.rpc;
const session_link = @import("../../session_link.zig");
const draw_list = @import("ra8_render").draw_list;
const colors = @import("../../ui/colors.zig");
const board_pane = @import("../../ui/board_pane.zig");
const board_capture = @import("../../board/capture.zig");
const lcd_pacing = @import("../../lcd_pacing.zig");
pub const input = @import("input.zig");

const Color = draw_list.Color;
const unseen = colors.unseen;

pub const Board = struct {
    allocator: std.mem.Allocator,
    pixels: []Color = &.{},
    width: u32 = 0,
    height: u32 = 0,
    /// The user LEDs as the session last reported them.
    leds: board_pane.Leds = .{},
    /// The union of the rectangles that arrived since the pane last drew
    /// them, in image pixels (RA8EMU-823); null until one arrives.
    dirty: ?draw_list.Rect = null,
    /// The board's parts as the session reported them (RA8EMU-1151); empty
    /// until the board_parts answer lands.
    parts: board_pane.Parts = .{},
    /// The owned label storage the reported parts point into, so the wire's
    /// bytes can die with the frame that carried them.
    led_store: [board_pane.max_leds]board_pane.Led = undefined,
    led_names: [board_pane.max_leds][board_pane.name_max]u8 = undefined,
    switch_names: [board_pane.max_switches][board_pane.name_max]u8 = undefined,
    switch_ptrs: [board_pane.max_switches][]const u8 = @splat(""),
    /// The id of the board_parts request still waiting for its answer.
    parts_id: u32 = 0,
    subscribed: bool = false,
    /// The pane's pacing model (RA8EMU-824): arrivals queue into it, and a
    /// frame shows at most once per refresh cap.
    pacer: lcd_pacing.Pacer = .{},
    /// Arrivals passed over since the last present (RA8EMU-824), for the
    /// pane's corner.
    skipped: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Board {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Board) void {
        self.allocator.free(self.pixels);
    }

    /// Subscribe both cores' board changes and session events, once, after the
    /// session greets. A session with no display refuses the first and
    /// still sends the second.
    pub fn attach(self: *Board, link: *session_link.Link) void {
        if (self.subscribed or link.state != .connected) return;
        for ([_]proto.Core{ .cpu0, .cpu1 }) |core| {
            for ([_]proto.Topic{ .lcd_dirty, .session }) |topic| {
                _ = link.send(proto.Subscription, .subscribe, .{ .core = core, .topic = topic }) catch return;
            }
        }
        self.subscribed = true;
        // An older server without board parts refuses it; the pane then
        // draws an empty board until a server that answers serves one.
        self.parts_id = link.send(proto.CoreOnly, .board_parts, .{ .core = .cpu0 }) catch 0;
    }

    /// Copy an lcd_dirty rectangle into the image, or fold an LED change
    /// into the LEDs.
    pub fn observe(self: *Board, arrival: session_link.Arrival, now_ns: u64) error{OutOfMemory}!void {
        switch (arrival) {
            .event => |event| try self.fold(event, now_ns),
            .response => |answer| if (answer.id == self.parts_id and self.parts_id != 0) self.takeParts(answer.result),
        }
    }

    /// Folds one session event into the LEDs or the panel image.
    fn fold(self: *Board, event: session_link.Env.Event, now_ns: u64) error{OutOfMemory}!void {
        if (event.topic == @backingInt(proto.Topic.session)) {
            const change = proto.decode(proto.SessionEvent, event.payload) catch return;
            board_capture.observe(&self.leds, self.parts.leds.len, change);
            return;
        }
        if (event.topic != @backingInt(proto.Topic.lcd_dirty)) return;
        const rect = proto.decode(proto.DirtyRect, event.payload) catch return;
        if (rect.pixels.len != @as(usize, rect.width) * rect.height) return;
        try self.cover(@as(u32, rect.x) + rect.width, @as(u32, rect.y) + rect.height);
        for (0..rect.height) |row| {
            const into = self.pixels[(rect.y + row) * self.width + rect.x ..][0..rect.width];
            for (into, rect.pixels[row * rect.width ..][0..rect.width]) |*pixel, gray| pixel.* = Color.rgb(gray, gray, gray);
        }
        self.pacer.arrive(rect.virtual_ns, now_ns);
        const landed = draw_list.Rect{ .x = @intCast(rect.x), .y = @intCast(rect.y), .w = @intCast(rect.width), .h = @intCast(rect.height) };
        self.dirty = if (self.dirty) |old| old.unionWith(landed) else landed;
    }

    /// The pacer's decision at `now_ns` (RA8EMU-824): a frame shows whenever
    /// the refresh cap allows, and everything passed over rides along in
    /// `skipped` for the pane's corner.
    pub fn pace(self: *Board, now_ns: u64) void {
        const decision = self.pacer.due(@as(i128, now_ns)) orelse return;
        self.pacer.present(decision.generation, @as(i128, now_ns));
        self.skipped = decision.skipped;
    }

    /// Gives the board its parts (RA8EMU-1151), copied into the owned
    /// stores; the wire answer and the tests both land here.
    pub fn setParts(self: *Board, leds: []const board_pane.Led, switch_names: []const []const u8, panel: board_pane.Profile) void {
        const count = @min(leds.len, board_pane.max_leds);
        for (0..count) |index| {
            self.led_names[index] = @splat(0);
            self.led_store[index] = .{ .rgb565 = leds[index].rgb565, .name = keep(&self.led_names[index], leds[index].name) };
        }
        const switch_count = @min(switch_names.len, board_pane.max_switches);
        for (0..switch_count) |index| {
            self.switch_names[index] = @splat(0);
            self.switch_ptrs[index] = keep(&self.switch_names[index], switch_names[index]);
        }
        self.parts = .{ .leds = self.led_store[0..count], .switch_names = self.switch_ptrs[0..switch_count], .panel = panel };
    }

    /// Takes the board_parts answer into the owned stores (RA8EMU-1151).
    fn takeParts(self: *Board, result: session_link.Env.Result) void {
        const ok = switch (result) {
            .ok => |bytes| bytes,
            .err => return,
        };
        const parts = proto.decode(proto.BoardParts, ok) catch return;
        const names = Lines{ .text = std.mem.trimEnd(u8, parts.led_names, "\n") };
        var leds: [board_pane.max_leds]board_pane.Led = undefined;
        const count = @min(@min(parts.led_colors.len / 2, names.count()), board_pane.max_leds);
        for (0..count) |index| {
            leds[index] = .{
                .rgb565 = std.mem.readInt(u16, parts.led_colors[index * 2 ..][0..2], .little),
                .name = names.at(index),
            };
        }
        const switches = Lines{ .text = std.mem.trimEnd(u8, parts.switch_names, "\n") };
        var given: [board_pane.max_switches][]const u8 = undefined;
        const switch_count = @min(switches.count(), board_pane.max_switches);
        for (0..switch_count) |index| given[index] = switches.at(index);
        self.setParts(leds[0..count], given[0..switch_count], .{ .width = parts.panel_width, .height = parts.panel_height });
    }

    /// The lines of a parts answer's name field, one per '\n'.
    const Lines = struct {
        text: []const u8,

        fn count(self: Lines) usize {
            if (self.text.len == 0) return 0;
            var total: usize = 1;
            for (self.text) |byte| {
                if (byte == '\n') total += 1;
            }
            return total;
        }

        fn at(self: Lines, index: usize) []const u8 {
            var start: usize = 0;
            var seen: usize = 0;
            for (self.text, 0..) |byte, end| {
                if (byte != '\n') continue;
                if (seen == index) return self.text[start..end];
                seen += 1;
                start = end + 1;
            }
            return if (seen == index) self.text[start..] else "";
        }
    };

    /// Whether any rectangle has arrived yet.
    pub fn hasFrame(self: *const Board) bool {
        return self.width != 0 and self.height != 0;
    }

    pub fn image(self: *const Board) draw_list.Image {
        return .{ .width = self.width, .height = self.height, .pixels = self.pixels };
    }

    /// What the board pane draws: the LEDs, the panel once a frame has
    /// arrived with the rectangles that arrived since the last draw
    /// (RA8EMU-823), and the switch the pointer holds down.
    pub fn view(self: *Board, pressed: ?usize) board_pane.View {
        const blank = draw_list.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        const dirty = self.dirty orelse blank;
        self.dirty = null;
        return .{ .leds = &self.leds, .panel = if (self.hasFrame()) self.image() else null, .dirty = dirty, .pressed = pressed, .skipped = self.skipped };
    }

    /// Grow the image to at least `width` by `height`, keeping what it holds.
    fn cover(self: *Board, width: u32, height: u32) error{OutOfMemory}!void {
        if (width <= self.width and height <= self.height) return;
        const wide = @max(width, self.width);
        const tall = @max(height, self.height);
        const grown = try self.allocator.alloc(Color, @as(usize, wide) * tall);
        @memset(grown, unseen);
        for (0..self.height) |row| {
            @memcpy(grown[row * wide ..][0..self.width], self.pixels[row * self.width ..][0..self.width]);
        }
        self.allocator.free(self.pixels);
        self.pixels = grown;
        self.width = wide;
        self.height = tall;
    }
};

/// Copies `text` into `store` and returns the kept prefix.
fn keep(store: *[board_pane.name_max]u8, text: []const u8) []const u8 {
    const n = @min(text.len, store.len);
    @memcpy(store[0..n], text[0..n]);
    return store[0..n];
}
