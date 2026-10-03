//! Tests for src/debug/zig_session.zig.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.core.cpu.bus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Machine = ra8.core.stop_machine.Machine;
const session_view = ra8.core.session_view;
const zig_session = ra8.core.step_hook.zig_session;

/// 64 bytes of RAM at address 0, the vector table first.
const Ram = struct {
    bytes: [64]u8,

    fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(ctx));
        if (address + from.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

// sp 0x40, reset 0x09 ; 0x08 bf00 nop ; 0x0A f3af 8000 nop.w ; 0x0E bf00 nop ; 0x10 ba80 (unallocated)
fn ram() Ram {
    var r: Ram = .{ .bytes = [_]u8{0} ** 64 };
    const image = [_]u8{
        0x40, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00,
        0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x00, 0xBF,
        0x80, 0xBA,
    };
    @memcpy(r.bytes[0..image.len], &image);
    return r;
}

test "run stops on a break and a second run is refused" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const id = try machine.addBreak(.{ .address = 0x0E });
    var session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    try std.testing.expectEqual(id, (try session.go(.run)).stop.breakpoint);
    try std.testing.expectEqual(@as(u32, 0x0E), cpu.regs.pc);
    try std.testing.expectError(zig_session.Error.AlreadyRunning, session.go(.run));
}

test "step runs one instruction and cont runs on to the core's own stop" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    var session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    try std.testing.expect((try session.go(.step)).stop == .stepped);
    try std.testing.expectEqual(@as(u32, 0x0A), cpu.regs.pc);
    try std.testing.expect((try session.go(.cont)) == .core);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.regs.pc);
}

test "finish runs until the return address in lr" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    cpu.regs.lr = 0x0F;
    var machine = Machine{};
    var session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 };
    try std.testing.expect((try session.go(.finish)).stop == .stepped);
    try std.testing.expectEqual(@as(u32, 0x0E), cpu.regs.pc);
}

test "the register dump reads the Zig core" {
    var memory = ram();
    var cpu: Cpu = .{ .bus = memory.view() };
    try cpu.reset(0);
    var machine = Machine{};
    const session: zig_session.ZigSession = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 };
    var text: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&text);
    try session_view.registers(stream.writer(), session.view());
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "pc  0x00000008") != null);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "sp  0x00000040") != null);
}
