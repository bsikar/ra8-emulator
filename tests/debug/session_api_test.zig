//! Host tests for the core-addressed session API.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const api = ra8.core.session_api;
const breakpoint = ra8.core.breakpoint;
const Machine = ra8.core.stop_machine.Machine;
const zig_session = ra8.core.step_hook.zig_session;

/// A small RAM image with an initial vector table and three Thumb instructions.
const Ram = struct {
    bytes: [64]u8 = [_]u8{0} ** 64,

    fn init() Ram {
        var memory: Ram = .{};
        const code = [_]u8{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xBF, 0x80, 0xBA };
        @memcpy(memory.bytes[0..code.len], &code);
        return memory;
    }

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + bytes.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..bytes.len], bytes);
    }
};

const LoadLog = struct {
    calls: [2]usize = .{ 0, 0 },

    fn load(context: *anyopaque, core: api.Core, image: []const u8) anyerror!void {
        const self: *LoadLog = @ptrCast(@alignCast(context));
        if (image.len == 0) return error.EmptyImage;
        self.calls[@intFromEnum(core)] += 1;
    }
};

const Events = struct {
    count: usize = 0,
    last: ?api.Event = null,

    fn receive(context: *anyopaque, event: api.Event) void {
        const self: *Events = @ptrCast(@alignCast(context));
        self.count += 1;
        self.last = event;
    }
};

test "one API loads and drives CPU0 and CPU1 with per-core registers, memory, and breakpoints" {
    var memory0 = Ram.init();
    var memory1 = Ram.init();
    var cpu0: Cpu = .{ .bus = memory0.view() };
    var cpu1: Cpu = .{ .bus = memory1.view() };
    try cpu0.reset(0);
    try cpu1.reset(0);
    var machine0 = Machine{};
    var machine1 = Machine{};
    var live: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu0 }, .machine = &machine0, .budget = 100 };
    live.other = .{ .core = .{ .cpu = &cpu1 }, .machine = &machine1, .budget = 100, .index = 1 };

    var session: api.Session = .{ .live = live };
    var loader: LoadLog = .{};
    session.attachLoader(.{ .context = &loader, .loadFn = LoadLog.load });
    var events: Events = .{};
    _ = try session.subscribe(.{ .context = &events, .receive = Events.receive });
    try std.testing.expect(session.hasCore(.cpu0));
    try std.testing.expect(session.hasCore(.cpu1));

    try session.load(.cpu0, "cpu0-image");
    try session.load(.cpu1, "cpu1-image");
    try std.testing.expectEqual(@as(usize, 1), loader.calls[0]);
    try std.testing.expectEqual(@as(usize, 1), loader.calls[1]);

    const id = try session.setBreakpoint(.cpu1, .{ .address = 0x0E });
    const ended1 = try session.run(.cpu1, .run);
    try std.testing.expectEqual(.breakpoint, std.meta.activeTag(ended1.stop));
    try std.testing.expectEqual(@as(u32, 0x0E), try session.register(.cpu1, .pc));
    try std.testing.expectEqual(@as(u32, 0x08), try session.register(.cpu0, .pc));

    try session.setRegister(.cpu0, .r0, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234), try session.register(.cpu0, .r0));
    try session.write(.cpu1, 0x20, &.{ 0x34, 0x12 });
    var bytes: [2]u8 = undefined;
    try session.read(.cpu1, 0x20, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, &bytes);

    try session.clearBreakpoint(.cpu1, id);
    try session.setSpeed(.cpu1, 2);
    try std.testing.expectEqual(@as(u64, 2_000_000), session.live.budget);
    const ended0 = try session.step(.cpu0);
    try std.testing.expectEqual(.stepped, std.meta.activeTag(ended0.stop));
    try std.testing.expectEqual(@as(u32, 0x0A), try session.register(.cpu0, .pc));
    _ = try session.register(.cpu1, .pc);
    try std.testing.expectEqual(@as(u64, 2_000_000), session.live.budget);
    try std.testing.expect(events.count >= 8);
    try session.pause(.cpu0);
    try std.testing.expectEqual(api.Event.Kind.paused, events.last.?.kind);
    try std.testing.expectEqual(api.Core.cpu0, events.last.?.core);
}
