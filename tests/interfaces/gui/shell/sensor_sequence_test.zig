//! Host test for the devices leaf's hot-plug sequence (RA8EMU-820): a
//! spawned `serve --stdio` boots firmware that polls the gauge and reports
//! its counts on the console SCI8 whenever the answer flips. The test plugs
//! the gauge through the shell's picker field, then drives unplug, replug,
//! set fault and clear through the leaf's own input handlers, and checks
//! the session events in order and a firmware report after each change.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const draw_list = ra8.render.draw_list;
const platform = gui_app.platform;
const pane_layout = gui_app.pane_layout;
const frame = gui_app.shell.frame;
const shell_devices = gui_app.shell.devices;
const fault = gui_app.shell.fault;
const shell_plug = gui_app.shell.plug;
const session_link = gui_app.session_link;
const Link = session_link.Link;
const Env = proto.Client.Env;

const image_path = "tests/fixtures/plug/gauge_uart.elf";
const spec = "max17048@i2c:riic@0x36";
const endpoint = "i2c:riic@0x36";
const width = 960;
const height = 640;

/// What one step still waits for, all at once: a parsed report line, this
/// many session events, a flip count, and growth past a saved side.
const Wait = struct {
    events_len: usize = 0,
    flips: u32 = 0,
    ack_above: u32 = 0,
    nack_above: u32 = 0,
    listed: bool = false,
    /// The part's fault mode this step waits for, none when unset.
    mode: ?usize = null,
};

/// The devices leaf and its faults and picker, fed in the shell's own
/// order, plus the session's events in order and the console's counts.
const Watch = struct {
    devices: shell_devices.Devices = .{},
    faults: fault.Faults = .{},
    plug: shell_plug.Plug = .{},
    kinds: [8]proto.EventKind = undefined,
    events: usize = 0,
    line: [64]u8 = undefined,
    len: usize = 0,
    counts: [4]u32 = .{ 0, 0, 0, 0 },
    reported: bool = false,
    ready: bool = false,
    wait: Wait = .{},

    fn observe(self: *Watch, arrival: session_link.Arrival) void {
        switch (arrival) {
            .event => |event| {
                if (event.topic == @backingInt(proto.Topic.uart)) {
                    const sent = proto.decode(proto.Uart, event.payload) catch return;
                    self.text(sent.bytes);
                    return;
                }
                if (event.topic != @backingInt(proto.Topic.session)) return;
                const said = proto.decode(proto.SessionEvent, event.payload) catch return;
                switch (said.kind) {
                    .plugged, .unplugged, .fault_set, .fault_cleared => {},
                    else => return,
                }
                if (self.events < self.kinds.len) {
                    self.kinds[self.events] = said.kind;
                    self.events += 1;
                }
            },
            .response => {},
        }
        if (self.plug.observe(arrival)) self.devices.want = true;
        self.devices.observe(arrival);
        if (self.faults.observe(arrival)) self.devices.want = true;
    }

    fn text(self: *Watch, bytes: []const u8) void {
        for (bytes) |char| {
            if (char == '\n') {
                if (std.mem.startsWith(u8, self.line[0..self.len], "P=")) {
                    self.reported = true;
                    self.parse();
                }
                if (std.mem.indexOf(u8, self.line[0..self.len], "ready") != null) self.ready = true;
                self.len = 0;
            } else if (self.len < self.line.len) {
                self.line[self.len] = char;
                self.len += 1;
            }
        }
    }

    /// "P=<polls> A=<acks> N=<nacks> C=<changes>" into counts.
    fn parse(self: *Watch) void {
        var index: usize = 0;
        while (index + 2 < self.len) : (index += 1) {
            const slot: ?usize = switch (self.line[index]) {
                'P' => 0,
                'A' => 1,
                'N' => 2,
                'C' => 3,
                else => null,
            };
            if (slot == null or self.line[index + 1] != '=') continue;
            index += 2;
            var value: u32 = 0;
            while (index < self.len and self.line[index] >= '0' and self.line[index] <= '9') : (index += 1) {
                value = value * 10 + (self.line[index] - '0');
            }
            self.counts[slot.?] = value;
        }
    }
};

/// Read the fixture's SRAM counters (diagnosis only, removed before merge).
fn nowMs() i64 {
    return std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds();
}

/// Pump `link` into `watch` for up to ten seconds, until `done` holds. While
/// waiting it keeps the served core going the way the shell does: one advance
/// slice of board time in flight at a time (RA8EMU-654), so every slice ends
/// in a `count` boundary and the next goes out only after the last answered.
fn pumpUntil(link: *Link, watch: *Watch, comptime done: fn (*const Watch, *const Link) bool) !void {
    const deadline = nowMs() + 10_000;
    var outstanding: usize = 0;
    while (nowMs() < deadline) {
        if (link.state != .connecting and link.state != .connected) return error.LinkDown;
        watch.devices.attach(link);
        if (link.pump()) |arrival| {
            switch (arrival) {
                .response => if (outstanding > 0) {
                    outstanding -= 1;
                },
                .event => {},
            }
            watch.observe(arrival);
            continue;
        }
        if (done(watch, link)) return;
        if (outstanding == 0 and link.state == .connected) {
            _ = try link.send(proto.Advance, .advance, .{ .core = .cpu0, .ns = 1000 });
            outstanding = 1;
        }
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.Timeout;
}

fn connected(_: *const Watch, link: *const Link) bool {
    return link.state == .connected;
}

fn reported(watch: *const Watch, _: *const Link) bool {
    return watch.reported;
}

/// The fixture's boot banner arrived, so the served core runs.
fn booted(watch: *const Watch, _: *const Link) bool {
    return watch.ready;
}

fn met(watch: *const Watch, link: *const Link) bool {
    const wait = watch.wait;
    if (watch.events < wait.events_len) return false;
    if (watch.counts[3] < wait.flips) return false;
    if (watch.counts[1] <= wait.ack_above) return false;
    if (watch.counts[2] <= wait.nack_above) return false;
    if (wait.listed and (watch.plug.asking != null or !watch.devices.answered or
        watch.devices.asked != null or watch.devices.want)) return false;
    if (wait.mode) |mode| if (watch.faults.modeOf(endpoint) != mode) return false;
    return connected(watch, link);
}

/// The row the part on `endpoint` sits on.
fn rowOf(devices: *const shell_devices.Devices) !usize {
    var row: usize = 0;
    while (devices.line(row)) |line| : (row += 1) {
        if (std.mem.eql(u8, shell_devices.split(line).at, endpoint)) return row;
    }
    return error.NotListed;
}

/// The first devices leaf's body, laid out the way the shell lays it out.
fn devicesBody(gpa: std.mem.Allocator) !draw_list.Rect {
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, width, height);
    defer solved.deinit(gpa);
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        return frame.bodyOf(leaf.area);
    }
    return error.NoDevicesLeaf;
}

/// Type the gauge's spec into the picker field and send it.
fn plugIn(watch: *Watch, link: *Link, body: draw_list.Rect) !void {
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    try shell_plug.draw(&list, &gui_app.colors.palettes.dark, body, &watch.devices, &watch.plug);
    const field = shell_plug.fieldRect(body);
    try std.testing.expect(watch.plug.press(field.x + 2, field.y + 2));
    var rest: []const u8 = spec;
    while (rest.len > 0) {
        const chunk = rest[0..@min(rest.len, 8)];
        try std.testing.expect(watch.plug.handle(.{ .text = platform.Text.of(chunk) }));
        rest = rest[chunk.len..];
    }
    _ = watch.plug.handle(.{ .key = .{ .code = 0x0D, .down = true } });
    try std.testing.expect(watch.plug.attach(link));
}

fn pressUnplug(watch: *Watch, link: *Link, row: usize) !void {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, width, height);
    defer solved.deinit(gpa);
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        const cell = shell_devices.unplugCell(frame.bodyOf(leaf.area), row);
        try std.testing.expect(watch.devices.clickIn(link, &layout, &solved, cell.x + 1, cell.y + 1));
        return;
    }
    return error.NoDevicesLeaf;
}

fn pressFault(watch: *Watch, link: *Link, row: usize) !void {
    const gpa = std.testing.allocator;
    var layout = try pane_layout.twoCore(gpa);
    defer layout.deinit();
    var solved = try frame.solve(&layout, gpa, width, height);
    defer solved.deinit(gpa);
    for (solved.panes.items) |leaf| {
        const placed = layout.pane(leaf.index) orelse continue;
        if (placed.kind != .devices) continue;
        const cell = fault.cell(frame.bodyOf(leaf.area), row);
        try std.testing.expect(watch.faults.clickIn(link, &watch.devices, &layout, &solved, cell.x + 1, cell.y + 1));
        return;
    }
    return error.NoDevicesLeaf;
}

test "the shell drives unplug, replug, fault and clear on a running image" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, image_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    var watch: Watch = .{};
    try watch.plug.init();
    try pumpUntil(&link, &watch, connected);
    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .session });
    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .uart });
    try pumpUntil(&link, &watch, booted);
    const body = try devicesBody(gpa);
    try plugIn(&watch, &link, body);
    watch.wait = .{ .flips = 1, .ack_above = 0, .events_len = 1, .listed = true };
    try pumpUntil(&link, &watch, met);
    try std.testing.expect(!watch.plug.refused);
    const row = try rowOf(&watch.devices);

    try pressUnplug(&watch, &link, row);
    watch.wait = .{ .flips = 2, .nack_above = 0, .events_len = 2 };
    try pumpUntil(&link, &watch, met);
    const nacks = watch.counts[2];

    try plugIn(&watch, &link, body);
    watch.wait = .{ .flips = 3, .ack_above = 0, .events_len = 3 };
    try pumpUntil(&link, &watch, met);
    try pressFault(&watch, &link, try rowOf(&watch.devices));
    watch.wait = .{ .flips = 4, .nack_above = nacks, .events_len = 4, .mode = 1 };
    try pumpUntil(&link, &watch, met);
    try std.testing.expectEqual(@as(usize, 1), watch.faults.modeOf(endpoint));

    // The cycle's later modes: nack:2 keeps nacking, stuck:0xff and
    // garbage:1 answer again, and the step back to none sends clear_fault.
    try pressFault(&watch, &link, try rowOf(&watch.devices));
    watch.wait = .{ .mode = 2 };
    try pumpUntil(&link, &watch, met);
    try std.testing.expectEqual(@as(usize, 2), watch.faults.modeOf(endpoint));

    try pressFault(&watch, &link, try rowOf(&watch.devices));
    watch.wait = .{ .mode = 3 };
    try pumpUntil(&link, &watch, met);
    try std.testing.expectEqual(@as(usize, 3), watch.faults.modeOf(endpoint));

    try pressFault(&watch, &link, try rowOf(&watch.devices));
    watch.wait = .{ .mode = 4 };
    try pumpUntil(&link, &watch, met);
    try std.testing.expectEqual(@as(usize, 4), watch.faults.modeOf(endpoint));

    try pressFault(&watch, &link, try rowOf(&watch.devices));
    watch.wait = .{ .mode = 0 };
    try pumpUntil(&link, &watch, met);
    try std.testing.expectEqual(@as(usize, 0), watch.faults.modeOf(endpoint));

    const want = [8]proto.EventKind{ .plugged, .unplugged, .plugged, .fault_set, .fault_set, .fault_set, .fault_set, .fault_cleared };
    try std.testing.expectEqualSlices(proto.EventKind, &want, watch.kinds[0..watch.events]);

    local.end();
    while (link.state == .connected) {
        if (link.pump() == null) try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}
