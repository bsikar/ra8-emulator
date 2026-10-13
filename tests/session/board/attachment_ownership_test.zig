//! Startup provenance survives orphaned faults without acquiring borrowed parts.
const std = @import("std");
const ra8 = @import("ra8");
const c = ra8.components;
const attachments = ra8.session.board.state.attachments;
const Rig = @import("attachments_test.zig").Rig;
const Plugs = ra8.session.board.plug.Plugs;
const Panel = c.eink.Panel;
const at: c.endpoint.Endpoint = .{ .spi = .{ .channel = 1, .select = 2 } };

fn startup(rig: *Rig) !*Panel {
    rig.board.asks.keep(rig.arena.allocator(), &.{.{ .name = "eink", .at = at }});
    try ra8.board.plug.all(&rig.board);
    rig.plugs = Plugs.init(&rig.board, rig.arena.allocator());
    return rig.board.asks.attached_eink.?;
}

fn pixels(panel: *Panel, allocator: std.mem.Allocator) !void {
    panel.planes.allocator = allocator;
    panel.planes.geometry = .{ .width = 3, .height = 2 };
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(2, 1, 0xa5);
}

const Observer = struct {
    frames: usize = 0,
    events: usize = 0,
    logs: usize = 0,
    pixel: u8 = 0,

    fn bind(self: *Observer, panel: *Panel) void {
        panel.refresh_hook = .{ .context = self, .refreshFn = frame };
        panel.event_hook = .{ .context = self, .refreshFn = event };
        panel.refresh_log_hook = .{ .context = self, .refreshFn = log };
    }

    fn frame(context: *anyopaque) void {
        const self: *Observer = @ptrCast(@alignCast(context));
        self.frames += 1;
    }

    fn event(context: *anyopaque, panel: *const Panel) void {
        const self: *Observer = @ptrCast(@alignCast(context));
        self.events += 1;
        self.pixel = panel.planes.glass.pixel(2, 1);
    }

    fn log(context: *anyopaque, value: c.eink.refresh.Event) void {
        const self: *Observer = @ptrCast(@alignCast(context));
        if (value.width == 3 and value.height == 2) self.logs += 1;
    }

    fn matches(self: *Observer, panel: *const Panel) !void {
        try std.testing.expect(panel.refresh_hook.?.context == @as(*anyopaque, self));
        try std.testing.expect(panel.event_hook.?.context == @as(*anyopaque, self));
        try std.testing.expect(panel.refresh_log_hook.?.context == @as(*anyopaque, self));
        try std.testing.expect(panel.refresh_hook.?.refreshFn == frame);
        try std.testing.expect(panel.event_hook.?.refreshFn == event);
        try std.testing.expect(panel.refresh_log_hook.?.refreshFn == log);
    }
};

fn word(rig: *Rig, value: u16) void {
    const device = rig.board.spi.channels[1].device.?;
    _ = device.exchange(@intCast(value >> 8));
    _ = device.exchange(@intCast(value & 0xff));
}

fn render(rig: *Rig) void {
    word(rig, c.eink.wire.preamble.command);
    word(rig, @backingInt(c.eink.wire.Command.display_area));
    for ([_]u16{ 0, 0, 3, 2, c.eink.wire.waveform.gc16 }) |value| {
        word(rig, c.eink.wire.preamble.write);
        word(rig, value);
    }
}

fn next(rig: *Rig) [4]u8 {
    var bytes: [4]u8 = undefined;
    for (&bytes) |*byte| byte.* = rig.board.spi.channels[1].device.?.exchange(0);
    return bytes;
}

test "ownership startup orphan fault keeps the actual endpoint" {
    const rig = try Rig.create();
    defer rig.destroy();
    _ = try startup(rig);
    try rig.faults.set(at, .{ .garbage = 713 });
    try rig.plugs.set(at, null);
    var graph: attachments.graph.Graph = .{};
    _ = try attachments.capture(&rig.board, rig.binding(), &graph);
    var found = false;
    for (graph.nodes[0..graph.count]) |node| {
        if (node.kind != .part and node.kind != .spi_fault) continue;
        found = true;
        try std.testing.expectEqualDeep(at, node.at);
    }
    try std.testing.expect(found);
}

test "ownership startup orphan first restore frees both host planes" {
    const rig = try Rig.create();
    defer rig.destroy();
    var empty = try rig.save();
    defer empty.deinit();
    var allocated = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const panel = try startup(rig);
    var committed = false;
    defer if (!committed) panel.deinit();
    try pixels(panel, allocated.allocator());
    try rig.faults.set(at, .{ .garbage = 713 });
    try rig.faults.set(at, null);
    try rig.plugs.set(at, null);
    try rig.restore(empty.written());
    committed = true;
    try std.testing.expectEqual(@as(usize, 12), allocated.allocated_bytes);
    try std.testing.expectEqual(allocated.allocated_bytes, allocated.freed_bytes);
    try rig.restore(empty.written());
}

test "ownership startup orphan providers pixels and served bytes survive first and repeated restore" {
    for (0..3) |trial| {
        const rig = try Rig.create();
        defer rig.destroy();
        var allocated = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const panel = try startup(rig);
        var committed = false;
        defer if (!committed) panel.deinit();
        try pixels(panel, allocated.allocator());
        var owned: Observer = .{};
        var builtin: Observer = .{};
        var displaced: Observer = .{};
        owned.bind(panel);
        builtin.bind(&rig.board.panel);
        try rig.faults.set(at, .{ .garbage = 713 });
        var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer saved.deinit();
        try rig.files.writeTo(&saved.writer);
        const expected = next(rig);
        if (trial == 1) try rig.faults.set(at, null);
        try rig.plugs.set(at, null);
        if (trial == 2) {
            try rig.plugs.set(at, "eink");
            displaced.bind(rig.plugs.panels[1].?);
        }
        try refused(rig, panel, &owned, &allocated, saved.written());
        for (0..3) |_| {
            try rig.files.readFrom(saved.written());
            committed = true;
            const restored = rig.board.asks.attached_eink.?;
            try owned.matches(restored);
            try std.testing.expectEqual(allocated.allocated_bytes, allocated.freed_bytes);
            try std.testing.expectEqualSlices(u8, &expected, &next(rig));
            try std.testing.expectEqual(@as(u8, 0xa5), restored.planes.image.pixel(2, 1));
            try rig.faults.set(at, null);
            render(rig);
            try std.testing.expectEqual(@as(u8, 0xaa), restored.planes.glass.pixel(2, 1));
        }
        try std.testing.expectEqual(@as(usize, 3), owned.frames);
        try std.testing.expectEqual(@as(usize, 3), owned.events);
        try std.testing.expectEqual(@as(usize, 3), owned.logs);
        try std.testing.expectEqual(@as(u8, 0xaa), owned.pixel);
        try std.testing.expectEqual(@as(usize, 0), builtin.events);
        try std.testing.expectEqual(@as(usize, 0), displaced.events);
    }
}

fn refused(rig: *Rig, panel: *Panel, observer: *Observer, allocated: *std.testing.FailingAllocator, bytes: []const u8) !void {
    const corrupt = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] = 0xff;
    rig.cpu.regs.low[4] = 0x12345678;
    try std.testing.expectError(error.BadValue, rig.files.readFrom(corrupt));
    const allocator = rig.board.bus.cells.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    rig.board.bus.cells.allocator = failing.allocator();
    const result = rig.files.readFrom(bytes);
    rig.board.bus.cells.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, result);
    try observer.matches(panel);
    try std.testing.expectEqual(@as(usize, 0), allocated.freed_bytes);
    try std.testing.expect(panel.planes.allocator.ptr == allocated.allocator().ptr);
    try std.testing.expectEqual(@as(u8, 0xa5), panel.planes.image.pixel(2, 1));
    try std.testing.expectEqual(@as(u32, 0x12345678), rig.cpu.regs.low[4]);
}

test "ownership borrowed known panel is not destroyed by a matching startup ask" {
    const rig = try Rig.create();
    defer rig.destroy();
    var empty = try rig.save();
    defer empty.deinit();
    var allocated = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const borrowed = try std.testing.allocator.create(Panel);
    defer std.testing.allocator.destroy(borrowed);
    borrowed.* = .{};
    defer borrowed.deinit();
    try pixels(borrowed, allocated.allocator());
    rig.board.asks.keep(rig.arena.allocator(), &.{.{ .name = "eink", .at = at }});
    rig.plugs = Plugs.init(&rig.board, rig.arena.allocator());
    rig.board.spi.channels[1].device = borrowed.device();
    try rig.restore(empty.written());
    try std.testing.expectEqual(@as(usize, 0), allocated.freed_bytes);
    try std.testing.expectEqual(@as(u8, 0xa5), borrowed.planes.image.pixel(2, 1));
}

test "ownership startup touch orphan keeps its actual line and restored bytes" {
    const rig = try Rig.create();
    defer rig.destroy();
    const touch: c.endpoint.Endpoint = .{ .i2c = .{ .line = .touch, .address = 0x36 } };
    rig.board.asks.keep(rig.arena.allocator(), &.{.{ .name = "max17048", .at = touch }});
    try ra8.board.plug.all(&rig.board);
    rig.plugs = Plugs.init(&rig.board, rig.arena.allocator());
    rig.board.wire.touchline.devices.find(0x36).?.write(c.max17048.reg.vcell);
    try rig.faults.set(touch, .{ .stuck = 0xa5 });
    try rig.plugs.set(touch, null);
    var graph: attachments.graph.Graph = .{};
    _ = try attachments.capture(&rig.board, rig.binding(), &graph);
    for (graph.nodes[0..graph.count]) |node| {
        if (node.kind == .part or node.kind == .i2c_fault) try std.testing.expectEqualDeep(touch, node.at);
    }
    var saved = try rig.save();
    defer saved.deinit();
    try rig.restore(saved.written());
    try std.testing.expect(rig.board.wire.touchline.devices.find(0x36) == null);
    const gauge = rig.plugs.snapshot_owned[0].device.i2c;
    var bytes: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), gauge.read(&bytes));
    try std.testing.expectEqualSlices(u8, &.{ 0xbe, 0 }, &bytes);
}
