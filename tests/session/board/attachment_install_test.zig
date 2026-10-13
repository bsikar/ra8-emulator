//! Commit ownership: orphaned wrappers and faulted startup parts clean up.
const std = @import("std");
const ra8 = @import("ra8");
const c = ra8.components;
const Rig = @import("attachments_test.zig").Rig;
const Plugs = ra8.session.board.plug.Plugs;
const Endpoint = c.endpoint.Endpoint;
const gauge_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const panel_at: Endpoint = .{ .spi = .{ .channel = 1, .select = 2 } };
const modem_at: Endpoint = .{ .uart = .{ .channel = 3 } };
const fixture = @import("attachment_ownership_test.zig");
const Panel = c.eink.Panel;
const attachments = ra8.session.board.state.attachments;

fn gauge(rig: *Rig) ![2]u8 {
    var bytes: [2]u8 = undefined;
    const device = rig.board.wire.controller.devices.find(0x36) orelse return error.Missing;
    try std.testing.expectEqual(@as(usize, 2), device.read(&bytes));
    return bytes;
}

test "attachment strict orphan cleared and displaced wrappers are replaced and cleaned up" {
    const rig = try Rig.create();
    defer rig.destroy();
    var empty = try rig.save();
    defer empty.deinit();
    try rig.plugs.set(gauge_at, "max17048");
    rig.board.wire.controller.devices.find(0x36).?.write(c.max17048.reg.soc);
    try rig.faults.set(gauge_at, .{ .stuck = 0xa5 });
    try rig.faults.set(gauge_at, null);
    try rig.plugs.set(panel_at, "eink");
    try rig.faults.set(panel_at, .{ .garbage = 987 });
    try rig.plugs.set(modem_at, "modem");
    try rig.faults.set(modem_at, .{ .garbage = 5 });
    try rig.plugs.set(gauge_at, null);
    try rig.plugs.set(panel_at, null);
    try rig.plugs.set(modem_at, null);
    var orphaned = try rig.save();
    defer orphaned.deinit();
    const kept = rig.plugs.instance_count;
    for ([_][]const u8{ empty.written(), orphaned.written(), orphaned.written(), empty.written() }, [_]usize{ 0, kept, kept, 0 }) |bytes, count| {
        try rig.restore(bytes);
        try std.testing.expectEqual(count, rig.plugs.instance_count);
        try std.testing.expectError(error.Missing, gauge(rig));
        try std.testing.expect(rig.board.serial.channels[3].device == null);
    }
    for (rig.faults.wrapped) |entry| try std.testing.expect(entry == null);
    for (rig.faults.spi_parts.held) |entry| try std.testing.expect(entry == null);
    for (rig.faults.uart_parts.held) |entry| try std.testing.expect(entry == null);
    try rig.plugs.set(gauge_at, "max17048");
    rig.board.wire.controller.devices.find(0x36).?.write(c.max17048.reg.soc);
    try std.testing.expectEqualSlices(u8, &.{ 72, 0 }, &try gauge(rig));
    try rig.faults.set(gauge_at, .{ .stuck = 0x11 });
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x11 }, &try gauge(rig));
}

test "attachment strict startup panel on a nonzero select under a fault restores and tears down" {
    const live = try Rig.create();
    defer live.destroy();
    const asks = [_]c.request.Request{.{ .name = c.parts.panel_name, .at = panel_at, .fault = .{ .garbage = 713 } }};
    live.board.asks.keep(live.arena.allocator(), &asks);
    try ra8.board.plug.all(&live.board);
    live.plugs = Plugs.init(&live.board, live.arena.allocator());
    _ = live.board.spi.channels[1].device.?.exchange(0);
    var saved = try live.save();
    defer saved.deinit();
    const expected = live.board.spi.channels[1].device.?.exchange(0);
    for (0..3) |_| {
        try live.restore(saved.written());
        try std.testing.expectEqual(expected, live.board.spi.channels[1].device.?.exchange(0));
    }
}

test "attachment strict runtime fault on startup panel retains its owned select and frees planes" {
    const live = try Rig.create();
    defer live.destroy();
    const asks = [_]c.request.Request{.{ .name = c.parts.panel_name, .at = panel_at }};
    live.board.asks.keep(live.arena.allocator(), &asks);
    try ra8.board.plug.all(&live.board);
    live.plugs = Plugs.init(&live.board, live.arena.allocator());
    const panel = live.board.asks.attached_eink.?;
    var restored = false;
    defer if (!restored) panel.deinit();
    panel.planes.allocator = std.testing.allocator;
    panel.planes.geometry = .{ .width = 3, .height = 2 };
    try std.testing.expect(panel.planes.ready());
    panel.planes.image.set(2, 1, 0xa5);
    try live.faults.set(panel_at, .{ .garbage = 713 });
    var graph: ra8.session.board.state.attachments.graph.Graph = .{};
    _ = try ra8.session.board.state.attachments.capture(&live.board, live.binding(), &graph);
    for (graph.nodes[0..graph.count]) |node| {
        if (node.kind == .part and node.kind.part == .panel) try std.testing.expectEqualDeep(panel_at, node.at);
    }
    var saved = try live.save();
    defer saved.deinit();
    try live.restore(saved.written());
    restored = true;
    try std.testing.expectEqual(@as(u8, 0xa5), live.board.asks.attached_eink.?.planes.image.pixel(2, 1));
    try live.restore(saved.written());
}

const Providers = struct {
    rig: *Rig,
    source: *Panel,
    committed: bool = false,
    left: fixture.Observer = .{},
    right: fixture.Observer = .{},
    builtin: fixture.Observer = .{},
    left_alloc: std.testing.FailingAllocator,
    right_alloc: std.testing.FailingAllocator,

    fn init(self: *Providers) !void {
        self.* = .{
            .rig = try Rig.create(),
            .source = undefined,
            .left_alloc = .init(std.testing.allocator, .{}),
            .right_alloc = .init(std.testing.allocator, .{}),
        };
        self.source = try fixture.startup(self.rig);
        try fixture.pixels(self.source, self.left_alloc.allocator());
        self.left.bind(self.source);
        self.builtin.bind(&self.rig.board.panel);
        try self.rig.faults.set(panel_at, .{ .garbage = 713 });
        try self.rig.plugs.set(panel_at, null);
        try self.rig.plugs.set(panel_at, "eink");
        try fixture.pixels(self.b(), self.right_alloc.allocator());
        self.b().planes.image.set(2, 1, 0x5a);
        self.right.bind(self.b());
    }

    fn deinit(self: *Providers) void {
        if (!self.committed) self.source.deinit();
        self.rig.destroy();
    }

    fn a(self: *Providers) *Panel {
        if (!self.committed) return self.source;
        return @ptrCast(@alignCast(self.rig.plugs.snapshot_owned[0].state));
    }

    fn b(self: *Providers) *Panel {
        return self.rig.plugs.panels[1].?;
    }

    fn save(self: *Providers) !std.Io.Writer.Allocating {
        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        errdefer out.deinit();
        try self.rig.files.writeTo(&out.writer);
        return out;
    }

    fn restore(self: *Providers, bytes: []const u8) !void {
        try self.rig.files.readFrom(bytes);
        self.committed = true;
    }

    fn matches(self: *Providers) !void {
        try self.left.matches(self.a());
        try self.right.matches(self.b());
        try std.testing.expectEqual(@as(usize, 1), self.rig.plugs.instance_count);
        if (self.committed) {
            try std.testing.expectEqual(@as(usize, 1), self.rig.plugs.snapshot_owned_count);
            try std.testing.expectEqual(@as(usize, 0), self.rig.board.asks.owned_count);
        }
        const freed: usize = if (self.committed) 12 else 0;
        try std.testing.expectEqual(@as(usize, 12), self.left_alloc.allocated_bytes);
        try std.testing.expectEqual(@as(usize, 12), self.right_alloc.allocated_bytes);
        try std.testing.expectEqual(freed, self.left_alloc.freed_bytes);
        try std.testing.expectEqual(freed, self.right_alloc.freed_bytes);
    }

    fn refused(self: *Providers, bytes: []const u8) !void {
        const old_a = self.a();
        const old_b = self.b();
        const ledger = self.rig.board.asks.owned_count;
        const copies = self.rig.plugs.snapshot_owned_count;
        self.rig.cpu.regs.low[4] = 0x12345678;
        const corrupt = try std.testing.allocator.dupe(u8, bytes);
        defer std.testing.allocator.free(corrupt);
        corrupt[corrupt.len - 1] = 0xff;
        try std.testing.expectError(error.BadValue, self.rig.files.readFrom(corrupt));
        const allocator = self.rig.board.bus.cells.allocator;
        for (0..4) |index| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = index });
            self.rig.board.bus.cells.allocator = failing.allocator();
            const result = attachments.prepare(&self.rig.board, self.rig.binding(), bytes);
            self.rig.board.bus.cells.allocator = allocator;
            try std.testing.expectError(error.OutOfMemory, result);
        }
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        self.rig.board.bus.cells.allocator = failing.allocator();
        const result = self.rig.files.readFrom(bytes);
        self.rig.board.bus.cells.allocator = allocator;
        try std.testing.expectError(error.OutOfMemory, result);
        try std.testing.expect(self.a() == old_a and self.b() == old_b);
        try std.testing.expectEqual(ledger, self.rig.board.asks.owned_count);
        try std.testing.expectEqual(copies, self.rig.plugs.snapshot_owned_count);
        try std.testing.expectEqual(@as(u32, 0x12345678), self.rig.cpu.regs.low[4]);
        try self.matches();
    }
};

fn panelBytes(panel: *Panel, count: usize) [16]u8 {
    var bytes: [16]u8 = @splat(0);
    for (bytes[0..count]) |*byte| byte.* = panel.exchange(0);
    return bytes;
}

test "provider binding both saved panels keep three distinct hooks through identical restores" {
    var held: Providers = undefined;
    try held.init();
    defer held.deinit();
    var saved = try held.save();
    defer saved.deinit();
    const left = panelBytes(held.a(), 4);
    const right = panelBytes(held.b(), 4);
    try held.refused(saved.written());
    for (0..3) |iteration| {
        try held.restore(saved.written());
        std.debug.print("provider saved A/B restore {d}\n", .{iteration + 1});
        try held.matches();
        try std.testing.expectEqualSlices(u8, &left, &panelBytes(held.a(), 4));
        try std.testing.expectEqualSlices(u8, &right, &panelBytes(held.b(), 4));
        try std.testing.expectEqual(@as(u8, 0xa5), held.a().planes.image.pixel(2, 1));
        try std.testing.expectEqual(@as(u8, 0x5a), held.b().planes.image.pixel(2, 1));
        fixture.render(held.rig);
        try std.testing.expectEqual(@as(u8, 0x55), held.right.pixel);
        try held.refused(saved.written());
    }
    try std.testing.expectEqual(@as(usize, 3), held.right.frames);
    try std.testing.expectEqual(@as(usize, 3), held.right.events);
    try std.testing.expectEqual(@as(usize, 3), held.right.logs);
    try std.testing.expectEqual(@as(usize, 0), held.left.events);
    try std.testing.expectEqual(@as(usize, 0), held.builtin.events);
}

test "provider binding runtime first cut snapshots continue against independent panel bytes" {
    var held: Providers = undefined;
    try held.init();
    defer held.deinit();
    var saved = try held.save();
    defer saved.deinit();
    const reference = try Rig.create();
    defer reference.destroy();
    try reference.files.readFrom(saved.written());
    var seed: u32 = 0x517cc1b7;
    for (0..7) |_| {
        const reference_a: *Panel = @ptrCast(@alignCast(reference.plugs.snapshot_owned[0].state));
        const reference_b = reference.plugs.panels[1].?;
        seed = seed *% 1664525 +% 1013904223;
        const cut: usize = @intCast((seed >> 8) % 11 + 1);
        const continued: usize = @intCast((seed >> 16) % 7 + 1);
        try held.restore(saved.written());
        try held.matches();
        const left = panelBytes(held.a(), cut);
        const right = panelBytes(held.b(), cut);
        try std.testing.expectEqualSlices(u8, &panelBytes(reference_a, cut), &left);
        try std.testing.expectEqualSlices(u8, &panelBytes(reference_b, cut), &right);
        var checkpoint = try held.save();
        defer checkpoint.deinit();
        const expected_left = panelBytes(reference_a, continued);
        const expected_right = panelBytes(reference_b, continued);
        _ = panelBytes(held.a(), 5);
        _ = panelBytes(held.b(), 5);
        for (0..2) |_| {
            try held.restore(checkpoint.written());
            try held.matches();
            try std.testing.expectEqualSlices(u8, &expected_left, &panelBytes(held.a(), continued));
            try std.testing.expectEqualSlices(u8, &expected_right, &panelBytes(held.b(), continued));
        }
        try reference.files.readFrom(saved.written());
    }
}

test "provider binding older startup only snapshot uses the remaining nonruntime donor" {
    const live = try Rig.create();
    defer live.destroy();
    var allocated = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const original = try fixture.startup(live);
    var committed = false;
    defer if (!committed) original.deinit();
    try fixture.pixels(original, allocated.allocator());
    var left: fixture.Observer = .{};
    var right: fixture.Observer = .{};
    left.bind(original);
    try live.faults.set(panel_at, .{ .garbage = 713 });
    var older = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer older.deinit();
    try live.files.writeTo(&older.writer);
    try live.plugs.set(panel_at, null);
    try live.plugs.set(panel_at, "eink");
    right.bind(live.plugs.panels[1].?);
    var both = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer both.deinit();
    try live.files.writeTo(&both.writer);
    try live.files.readFrom(both.written());
    committed = true;
    for (0..3) |_| {
        try live.files.readFrom(older.written());
        try left.matches(live.board.asks.attached_eink.?);
        try std.testing.expectEqual(@as(usize, 0), live.plugs.instance_count);
        try std.testing.expectEqual(@as(usize, 12), allocated.freed_bytes);
        try live.faults.set(panel_at, null);
        fixture.render(live);
    }
    try std.testing.expectEqual(@as(usize, 3), left.events);
    try std.testing.expectEqual(@as(usize, 0), right.events);
}
