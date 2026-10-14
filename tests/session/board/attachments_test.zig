//! Direct bus observations and late-failure oracles for attachment snapshots.
const std = @import("std");
const ra8 = @import("ra8");
const attachments = ra8.session.board.state.attachments;
const codec = ra8.components.catalog_snapshot;
const Board = ra8.board.board.Board;
const Plugs = ra8.session.board.plug.Plugs;
const Faults = ra8.session.board.faults.Faults;
const Endpoint = ra8.components.endpoint.Endpoint;
const gauge_at: Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
const panel_at: Endpoint = .{ .spi = .{ .channel = 1, .select = 2 } };
const modem_at: Endpoint = .{ .uart = .{ .channel = 3 } };

pub const Rig = struct {
    board: Board,
    arena: std.heap.ArenaAllocator,
    plugs: Plugs,
    faults: Faults,
    store: ra8.chip.core.cpu.memory.store.Store,
    bus: ra8.chip.core.cpu.memory.guest.bus.GuestBus,
    cpu: ra8.chip.core.cpu.cpu.Cpu,
    machine: ra8.session.stop_machine.Machine,
    session: ra8.session.api.Session,
    edge: ra8.session.board.boundary.BoardBoundary,
    files: ra8.session.board.state.Files,

    pub fn create() !*Rig {
        const self = try std.testing.allocator.create(Rig);
        self.board = Board.init(std.testing.allocator);
        self.arena = .init(std.testing.allocator);
        self.plugs = Plugs.init(&self.board, self.arena.allocator());
        self.faults = Faults.init(&self.board, self.arena.allocator());
        self.store = try ra8.chip.core.cpu.memory.store.Store.init(null);
        try ra8.board.wiring.attachBlocks(&self.board, .{ .store = &self.store });
        self.bus = ra8.chip.core.cpu.memory.guest.bus.GuestBus.of(&.{ .store = &self.store }, false);
        self.cpu = .{ .bus = self.bus.view() };
        self.machine = .{};
        self.session = .{ .live = .{ .core = .{ .cpu = &self.cpu }, .machine = &self.machine, .budget = 100 } };
        self.edge = .{ .board = &self.board, .core = .{ .store = &self.store }, .cpu = &self.cpu };
        self.files = .{ .store = &self.store, .cpu = &self.cpu, .board = &self.board, .edge = &self.edge, .session = &self.session, .attachments = self.binding() };
        return self;
    }

    pub fn destroy(self: *Rig) void {
        self.plugs.deinit();
        self.arena.deinit();
        self.board.deinit();
        self.store.deinit();
        std.testing.allocator.destroy(self);
    }

    pub fn binding(self: *Rig) attachments.Binding {
        return .{ .arena = &self.arena, .plugs = &self.plugs, .faults = &self.faults };
    }

    pub fn save(self: *Rig) !std.Io.Writer.Allocating {
        var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
        errdefer writer.deinit();
        try ra8.snapshot.file.writeHeader(&writer.writer);
        try attachments.save(&self.board, self.binding(), &writer.writer);
        return writer;
    }

    pub fn restore(self: *Rig, bytes: []const u8) !void {
        var staged = try attachments.prepare(&self.board, self.binding(), bytes);
        defer staged.deinit();
        staged.commit(&self.board, self.binding());
    }

    pub fn gauge(self: *Rig) ra8.chip.periph.riic.bus.Device {
        return self.board.wire.controller.devices.find(0x36).?.*;
    }
};

test "attachment strict next gauge bytes survive unplug replug and fresh restore" {
    const live = try Rig.create();
    defer live.destroy();
    try live.plugs.set(gauge_at, "max17048");
    live.gauge().write(ra8.components.max17048.reg.soc);
    var saved = try live.save();
    defer saved.deinit();
    var expected: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), live.gauge().read(&expected));
    try std.testing.expectEqualSlices(u8, &.{ 72, 0 }, &expected);
    try live.plugs.set(gauge_at, null);
    try live.plugs.set(gauge_at, "max17048");
    try live.restore(saved.written());
    var actual: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), live.gauge().read(&actual));
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    const fresh = try Rig.create();
    defer fresh.destroy();
    try fresh.restore(saved.written());
    try std.testing.expectEqual(@as(usize, 2), fresh.gauge().read(&actual));
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expectEqual(@as(usize, 1), live.plugs.instance_count);
}

test "attachment strict I2C noise phase slow and cleared wrapper keep next reads" {
    const source = try Rig.create();
    defer source.destroy();
    try source.plugs.set(gauge_at, "max17048");
    try source.faults.set(gauge_at, .{ .garbage = 12345 });
    source.gauge().write(2);
    try std.testing.expect(source.gauge().acks());
    var discarded: [2]u8 = undefined;
    _ = source.gauge().read(&discarded);
    var saved = try source.save();
    defer saved.deinit();
    var expected: [2]u8 = undefined;
    _ = source.gauge().read(&expected);
    const target = try Rig.create();
    defer target.destroy();
    try target.restore(saved.written());
    var actual: [2]u8 = undefined;
    _ = target.gauge().read(&actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expectEqual(@as(u32, 1), target.faults.wrapped[0].?.phases);
    try target.faults.set(gauge_at, null);
    try target.faults.set(gauge_at, .{ .slow_ns = 100 });
    target.gauge().write(8);
    var slow = try target.save();
    defer slow.deinit();
    const wrote = target.faults.wrapped[0].?.wrote;
    target.gauge().stop();
    try std.testing.expect(!target.gauge().acks());
    try target.restore(slow.written());
    try std.testing.expectEqual(wrote, target.faults.wrapped[0].?.wrote);
    target.gauge().stop();
    try std.testing.expectEqual(@as(u64, 100), target.faults.wrapped[0].?.ready_at);
    try std.testing.expect(!target.gauge().acks());
    try target.faults.set(gauge_at, null);
    var clear = try target.save();
    defer clear.deinit();
    try target.faults.set(gauge_at, .{ .stuck = 0xa5 });
    try target.restore(clear.written());
    try std.testing.expect(target.faults.wrapped[0].?.mode == .none);
}

test "attachment strict SPI and UART garbage and stuck match original bytes" {
    const source = try Rig.create();
    defer source.destroy();
    try source.plugs.set(panel_at, "eink");
    try source.plugs.set(modem_at, "modem");
    try source.faults.set(panel_at, .{ .garbage = 713 });
    try source.faults.set(modem_at, .{ .garbage = 914 });
    _ = source.board.spi.channels[1].device.?.exchange(0);
    _ = source.board.serial.channels[3].device.?.feed('A');
    _ = source.board.serial.channels[3].device.?.feed('T');
    var saved = try source.save();
    defer saved.deinit();
    const expected_spi = source.board.spi.channels[1].device.?.exchange(0);
    const response = source.board.serial.channels[3].device.?.feed(13);
    var expected_uart: [256]u8 = undefined;
    @memcpy(expected_uart[0..response.len], response);
    const target = try Rig.create();
    defer target.destroy();
    try target.restore(saved.written());
    try std.testing.expectEqual(expected_spi, target.board.spi.channels[1].device.?.exchange(0));
    try std.testing.expectEqualSlices(u8, expected_uart[0..response.len], target.board.serial.channels[3].device.?.feed(13));
    try target.faults.set(panel_at, .{ .stuck = 0xa5 });
    try target.faults.set(modem_at, .{ .stuck = 0x5a });
    var stuck = try target.save();
    defer stuck.deinit();
    try target.faults.set(panel_at, null);
    try target.faults.set(modem_at, null);
    try target.restore(stuck.written());
    try std.testing.expectEqual(@as(u8, 0xa5), target.board.spi.channels[1].device.?.exchange(0));
    const said = target.board.serial.channels[3].device.?.feed(13);
    try std.testing.expect(said.len > 0);
    for (said) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
}

test "attachment strict cleared displaced wrappers and unplugged topology are retained" {
    const rig = try Rig.create();
    defer rig.destroy();
    try rig.plugs.set(gauge_at, "max17048");
    try rig.faults.set(gauge_at, .{ .stuck = 0xa5 });
    try rig.faults.set(gauge_at, null);
    const old = rig.faults.wrapped[0].?;
    old.phases = 77;
    try rig.plugs.set(gauge_at, null);
    try rig.plugs.set(panel_at, "eink");
    try rig.faults.set(panel_at, .{ .garbage = 987 });
    _ = rig.board.spi.channels[1].device.?.exchange(0);
    const noise = rig.faults.spi_parts.held[1].?.noise;
    try rig.plugs.set(panel_at, null);
    var saved = try rig.save();
    defer saved.deinit();
    try rig.plugs.set(gauge_at, "max17048");
    try rig.plugs.set(panel_at, "eink");
    try rig.restore(saved.written());
    try std.testing.expect(rig.board.wire.controller.devices.find(0x36) == null);
    try std.testing.expect(ra8.session.board.plug.floating.holds(rig.board.spi.channels[1].device.?));
    try std.testing.expectEqual(@as(u32, 77), rig.faults.wrapped[0].?.phases);
    try std.testing.expect(rig.faults.wrapped[0].?.mode == .none);
    try std.testing.expectEqual(noise, rig.faults.spi_parts.held[1].?.noise);
    try rig.plugs.set(panel_at, "eink");
    try std.testing.expect(!ra8.session.board.plug.floating.holds(rig.board.spi.channels[1].device.?));
}

test "attachment strict startup named and fault only asks have typed graph state" {
    const source = try Rig.create();
    defer source.destroy();
    const asks = [_]ra8.components.request.Request{
        .{ .name = "max17048", .at = gauge_at, .fault = .{ .garbage = 78 } },
        .{ .name = "", .at = .{ .i2c = .{ .line = .riic, .address = 0x43 } }, .fault = .{ .stuck = 0x66 } },
    };
    source.board.asks.keep(source.arena.allocator(), &asks);
    try ra8.board.plug.all(&source.board);
    source.plugs = Plugs.init(&source.board, source.arena.allocator());
    source.gauge().write(2);
    var saved = try source.save();
    defer saved.deinit();
    var expected: [2]u8 = undefined;
    _ = source.gauge().read(&expected);
    const target = try Rig.create();
    defer target.destroy();
    try target.restore(saved.written());
    var actual: [2]u8 = undefined;
    _ = target.gauge().read(&actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    const expander = target.board.wire.controller.devices.find(0x43).?.*;
    expander.write(1);
    try std.testing.expectEqual(@as(usize, 1), expander.read(actual[0..1]));
    try std.testing.expectEqual(@as(u8, 0x66), actual[0]);
    try std.testing.expectEqual(@as(usize, 2), target.board.asks.count);
    try std.testing.expectEqual(@as(usize, 1), target.plugs.snapshot_owned_count);
}

test "attachment strict late corruption and failed allocation leave guest and host bindings unchanged" {
    const rig = try Rig.create();
    defer rig.destroy();
    try rig.plugs.set(gauge_at, "max17048");
    try rig.faults.set(gauge_at, .{ .garbage = 245 });
    rig.gauge().write(2);
    var saved = try rig.save();
    defer saved.deinit();
    const pointer = rig.gauge().context;
    const noise = rig.faults.wrapped[0].?.noise;
    const corrupt = try std.testing.allocator.dupe(u8, saved.written());
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] = 0xff;
    try std.testing.expectError(error.BadValue, rig.restore(corrupt));
    try std.testing.expect(pointer == rig.gauge().context);
    try std.testing.expectEqual(noise, rig.faults.wrapped[0].?.noise);
    const allocator = rig.board.bus.cells.allocator;
    defer rig.board.bus.cells.allocator = allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    rig.board.bus.cells.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, rig.restore(saved.written()));
    try std.testing.expect(pointer == rig.gauge().context);
    try std.testing.expectEqual(noise, rig.faults.wrapped[0].?.noise);
}

fn repaint(_: *anyopaque) void {}

test "attachment strict outer Files late section leaves memory core debug and host state unchanged" {
    const rig = try Rig.create();
    defer rig.destroy();
    try rig.plugs.set(gauge_at, "max17048");
    rig.gauge().write(4);
    rig.cpu.regs.low[0] = 7;
    const address = ra8.chip.core.memmap.sram_base + 0x100;
    try rig.store.write(.none, address, &.{12});
    var saved = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer saved.deinit();
    try rig.files.writeTo(&saved.writer);
    const pointer = rig.gauge().context;
    rig.cpu.regs.low[0] = 88;
    try rig.store.write(.none, address, &.{99});
    rig.machine.dwt.comps[0] = 0xabc;
    rig.board.panel.refresh_hook = .{ .context = rig, .refreshFn = repaint };
    const corrupt = try std.testing.allocator.dupe(u8, saved.written());
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] = 0xff;
    try std.testing.expectError(error.BadValue, rig.files.readFrom(corrupt));
    try std.testing.expectEqual(@as(u32, 88), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u8, 99), rig.store.span(address, 1).?[0]);
    try std.testing.expectEqual(@as(u32, 0xabc), rig.machine.dwt.comps[0]);
    try std.testing.expect(pointer == rig.gauge().context);
    try std.testing.expect(rig.board.panel.refresh_hook.?.context == @as(*anyopaque, rig));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const allocator = rig.board.bus.cells.allocator;
    rig.board.bus.cells.allocator = failing.allocator();
    const failed = rig.files.readFrom(saved.written());
    rig.board.bus.cells.allocator = allocator;
    try std.testing.expectError(error.OutOfMemory, failed);
    try std.testing.expectEqual(@as(u32, 88), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u8, 99), rig.store.span(address, 1).?[0]);
    try std.testing.expectEqual(@as(u32, 0xabc), rig.machine.dwt.comps[0]);
    try std.testing.expect(pointer == rig.gauge().context);
    try std.testing.expect(rig.board.panel.refresh_hook.?.context == @as(*anyopaque, rig));
    try rig.files.readFrom(saved.written());
    try std.testing.expectEqual(@as(u32, 7), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u8, 12), rig.store.span(address, 1).?[0]);
    var actual: [2]u8 = undefined;
    _ = rig.gauge().read(&actual);
    try std.testing.expectEqualSlices(u8, &.{ 72, 0 }, &actual);
    try std.testing.expect(rig.board.panel.refresh_hook.?.context == @as(*anyopaque, rig));
}

test "attachment strict I2C stuck and all cleared lines serve independent device bytes" {
    const source = try Rig.create();
    defer source.destroy();
    try source.plugs.set(gauge_at, "max17048");
    try source.plugs.set(panel_at, "eink");
    try source.plugs.set(modem_at, "modem");
    try source.faults.set(gauge_at, .{ .stuck = 0xa5 });
    source.gauge().write(4);
    var stuck = try source.save();
    defer stuck.deinit();
    const target = try Rig.create();
    defer target.destroy();
    try target.restore(stuck.written());
    var actual: [2]u8 = undefined;
    _ = target.gauge().read(&actual);
    try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5 }, &actual);
    try source.faults.set(gauge_at, null);
    try source.faults.set(panel_at, .{ .garbage = 100 });
    try source.faults.set(modem_at, .{ .stuck = 0x12 });
    try source.faults.set(panel_at, null);
    try source.faults.set(modem_at, null);
    const panel = codec.cast(ra8.components.eink.Panel, source.plugs.instances[1].state);
    panel.burst.stage(0x1234);
    _ = source.board.serial.channels[3].device.?.feed('A');
    _ = source.board.serial.channels[3].device.?.feed('T');
    var clear = try source.save();
    defer clear.deinit();
    var expected_i2c: [2]u8 = undefined;
    _ = source.gauge().read(&expected_i2c);
    var expected_spi: [4]u8 = undefined;
    for (&expected_spi) |*byte| byte.* = source.board.spi.channels[1].device.?.exchange(0);
    const response = source.board.serial.channels[3].device.?.feed(13);
    var expected_uart: [256]u8 = undefined;
    @memcpy(expected_uart[0..response.len], response);
    try target.restore(clear.written());
    _ = target.gauge().read(&actual);
    try std.testing.expectEqualSlices(u8, &.{ 72, 0 }, &actual);
    try std.testing.expectEqualSlices(u8, &expected_i2c, &actual);
    var spi: [4]u8 = undefined;
    for (&spi) |*byte| byte.* = target.board.spi.channels[1].device.?.exchange(0);
    try std.testing.expectEqualSlices(u8, &expected_spi, &spi);
    try std.testing.expectEqualSlices(u8, expected_uart[0..response.len], target.board.serial.channels[3].device.?.feed(13));
}
