//! Session display calls wait on virtual panel time and return raw frames.
const std = @import("std");
const ra8 = @import("ra8");
const api = ra8.core.session_api;
const Host = ra8.board.session_display.Host;
const Cpu = ra8.core.cpu.cpu.Cpu;
const bus = ra8.core.cpu.bus;
const Store = ra8.core.cpu.memory.store.Store;
const Guest = ra8.core.cpu.memory.guest.Guest;
const Machine = ra8.core.stop_machine.Machine;
const zig_session = ra8.core.step_hook.zig_session;
const gt911 = ra8.periph.i3c_gt911;

const Ram = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,

    fn init() Ram {
        var ram: Ram = .{};
        const code = [_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF, 0x00, 0xBF };
        @memcpy(ram.bytes[0..code.len], &code);
        return ram;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(context: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(context));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(context: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(context));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

/// A tiny host-side screen reacts only after the board delivered the tap to GT911.
const TapScreen = struct {
    session: *api.Session,
    board: *ra8.board.Board,
    contact: ?gt911.Contact = null,
    started: bool = false,

    fn advance(context: *anyopaque, max_ns: u64) anyerror!void {
        _ = max_ns;
        const self: *TapScreen = @ptrCast(@alignCast(context));
        const command: api.Run = if (self.started) .cont else .run;
        self.started = true;
        _ = try self.session.run(.cpu0, command);
        if (self.contact != null) return;
        const point = firmwareReport(&self.board.wire.panel) orelse return;
        self.contact = point;
        self.board.panel.planes.glass.pixels[0] = 0x81;
        self.board.panel.film.start();
        for (0..6) |_| _ = self.board.panel.film.poll();
    }
};

const Idle = struct {
    board: *ra8.board.Board,

    fn advance(context: *anyopaque, amount_ns: u64) anyerror!void {
        const self: *Idle = @ptrCast(@alignCast(context));
        self.board.time.base.advance(amount_ns);
    }
};

test "tap reaches GT911, settles e-ink, and returns a changed native grayscale frame" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.asks.attached_eink = &board.panel;
    board.panel.planes.resize(.{ .width = 1072, .height = 1448 });
    try std.testing.expect(board.panel.planes.ready());

    var ram = Ram.init();
    var cpu: Cpu = .{ .bus = ram.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1000 };
    var session: api.Session = .{ .live = live };
    session.attachTimeBase(&board.time.base);
    const event_id = session.event_stream.subscribe().?;

    var guest_store = try Store.init(null);
    defer guest_store.deinit();
    const guest: Guest = .{ .store = &guest_store };
    try ra8.board.wiring.attachBlocks(&board, guest);
    session.attachInputScript(&board.input_script);
    session.attachBoard(.cpu0, board.ticker(), guest);

    var screen: TapScreen = .{ .session = &session, .board = &board };
    var host = Host.init(std.testing.allocator, &board, .{
        .context = &screen,
        .advanceFn = TapScreen.advance,
    });
    defer host.deinit();
    session.attachDisplay(host.interface());

    var before = try session.frame(std.testing.allocator);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1072), before.width);
    var frame_events: [2]api.Event = undefined;
    const queued = session.event_stream.read(event_id, &frame_events).?;
    try std.testing.expectEqual(@as(usize, 1), queued.count);
    try std.testing.expectEqual(api.Event.Kind.lcd_frame, frame_events[0].kind);
    try std.testing.expectEqual(@as(u32, 1072), frame_events[0].payload.frame.width);
    try std.testing.expectEqual(@as(u16, 1448), frame_events[0].payload.frame.dirty.height);
    try std.testing.expectEqual(@as(u32, 1448), before.height);
    try session.tap(.cpu0, board.time.base.now() + 1, 300, 400);

    try session.waitSettled(100_000_000);
    try std.testing.expectEqual(gt911.Contact{ .x = 300, .y = 400 }, screen.contact.?);
    var after = try session.frame(std.testing.allocator);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, board.time.base.now()), after.virtual_ns);
    try std.testing.expect(!std.mem.eql(u8, before.pixels, after.pixels));
    const ppm = try after.ppm(std.testing.allocator);
    defer std.testing.allocator.free(ppm);
    try std.testing.expect(std.mem.startsWith(u8, ppm, "P6\n1072 1448\n255\n"));
}

test "session display reports a timeout when no refresh settles" {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    board.asks.attached_eink = &board.panel;
    board.panel.planes.resize(.{ .width = 1, .height = 1 });
    try std.testing.expect(board.panel.planes.ready());

    var idle: Idle = .{ .board = &board };
    var host = Host.init(std.testing.allocator, &board, .{
        .context = &idle,
        .advanceFn = Idle.advance,
    });
    defer host.deinit();
    var session: api.Session = .{ .live = undefined };
    session.attachDisplay(host.interface());
    try std.testing.expectError(error.Timeout, session.waitSettled(2_000_000));
}

fn firmwareReport(panel: *gt911.Panel) ?gt911.Contact {
    var status: [1]u8 = undefined;
    panel.pointer = gt911.reg.status;
    _ = panel.read(&status);
    if (status[0] & gt911.status.ready == 0) return null;
    var record: [gt911.record.bytes]u8 = undefined;
    panel.pointer = gt911.reg.point0;
    _ = panel.read(&record);
    panel.pointer = gt911.reg.status;
    panel.taken = gt911.pointer_bytes;
    panel.write(0);
    return .{ .x = @as(u16, record[2]) << 8 | record[1], .y = @as(u16, record[4]) << 8 | record[3] };
}
