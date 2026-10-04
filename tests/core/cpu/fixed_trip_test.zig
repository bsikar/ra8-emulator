//! Covers src/core/cpu/fixed_trip.zig: a loop whose trip changes nothing
//! retires at once (RA8EMU-463).
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("exception/ram.zig");
const Fake = @import("exception/fake_source.zig").Fake;
const QuietSource = ra8.core.cpu.exception.quiet_source.QuietSource;
const BlockCache = ra8.core.cpu.decode.block_cache.BlockCache;
const Cpu = ra8.core.cpu.cpu.Cpu;
const Stop = ra8.core.cpu.cpu.Stop;
const fixed_trip = ra8.core.cpu.cpu.fixed_trip;

/// A core on the fixture RAM polling through a settled quiet source, with
/// formed blocks, as park_test.zig builds it.
const Rig = struct {
    ram: fixture.Ram = .{},
    fake: Fake = .{},
    quiet: QuietSource = undefined,
    cache: *BlockCache = undefined,
    cpu: Cpu = undefined,

    fn init(self: *Rig, code: []const u16) !void {
        for (code, 0..) |half, i| self.ram.putHalf(fixture.code + @as(u32, @intCast(2 * i)), half);
        self.cpu = try fixture.boot(&self.ram);
        self.quiet = .{ .inner = self.fake.source(), .memory = self.ram.view() };
        self.cache = try std.testing.allocator.create(BlockCache);
        self.cache.init();
        self.cpu.bus = self.quiet.bus();
        self.cpu.source = self.quiet.source();
        self.cpu.quiet = &self.quiet;
        self.cpu.blocks = self.cache;
        aim(&self.cpu);
    }

    fn deinit(self: *Rig) void {
        std.testing.allocator.destroy(self.cache);
    }
};

const flag: u32 = fixture.base + 0x200;
const copy: u32 = fixture.base + 0x204;

fn aim(cpu: *Cpu) void {
    cpu.regs.set(0, copy);
    cpu.regs.set(1, 0);
    cpu.regs.set(2, flag);
}

/// The same code stepped one instruction at a time, with no shortcut.
fn plain(ram: *fixture.Ram, code: []const u16, count: u64) !Cpu {
    for (code, 0..) |half, i| ram.putHalf(fixture.code + @as(u32, @intCast(2 * i)), half);
    var cpu = try fixture.boot(ram);
    aim(&cpu);
    try std.testing.expectEqual(Stop.count, cpu.run(count));
    return cpu;
}

// ThreadX's __tx_ts_wait, from arm-none-eabi-as 13.3:
// head: cpsid i; ldr r1, [r2]; str r1, [r0]; cbnz r1, ready; cpsie i;
// b head; ready: b ready.
const ts_wait = [_]u16{ 0xB672, 0x6811, 0x6001, 0xB909, 0xB662, 0xE7F9, 0xE7FE };
// adds r3, #1; b back.
const count_loop = [_]u16{ 0x3301, 0xE7FD };
// adds r3, #1; str r3, [r0]; b back.
const store_loop = [_]u16{ 0x3301, 0x6003, 0xE7FC };

test "an idle __tx_ts_wait retires whole trips at once and ends where stepping would" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.run(1003));
    var ram: fixture.Ram = .{};
    const stepped = try plain(&ram, &ts_wait, 1003);
    try std.testing.expectEqual(stepped.retired, rig.cpu.retired);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&stepped.regs), std.mem.asBytes(&rig.cpu.regs)));
    // Stepped, the loop would start its two blocks about 330 times.
    try std.testing.expect(rig.cache.reused < 16);
}

test "the real bus is back once run returns" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    const before = rig.cpu.bus;
    _ = rig.cpu.run(3);
    try std.testing.expectEqual(before.ctx, rig.cpu.bus.ctx);
    try std.testing.expectEqual(before.vtable, rig.cpu.bus.vtable);
    try std.testing.expect(!rig.cpu.trip.on);
}

test "a ready flag ends the wait on the next trip" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    rig.ram.putWord(flag, 7);
    try std.testing.expectEqual(Stop.count, rig.cpu.run(20));
    try std.testing.expectEqual(fixture.code + 12, rig.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 7), rig.ram.word(copy));
}

test "a trip that changes a register is stepped" {
    var rig: Rig = .{};
    try rig.init(&count_loop);
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.run(1000));
    try std.testing.expectEqual(@as(u64, 1000), rig.cpu.retired);
    try std.testing.expectEqual(@as(u32, 500), rig.cpu.regs.get(3));
}

test "a trip that stores a new value is stepped" {
    var rig: Rig = .{};
    try rig.init(&store_loop);
    defer rig.deinit();
    try std.testing.expectEqual(Stop.count, rig.cpu.run(999));
    try std.testing.expectEqual(@as(u32, 333), rig.cpu.regs.get(3));
    try std.testing.expectEqual(@as(u32, 333), rig.ram.word(copy));
}

test "a pending interrupt is still taken" {
    var rig: Rig = .{};
    try rig.init(&ts_wait);
    defer rig.deinit();
    _ = rig.cpu.run(50);
    rig.fake.pending = .{ .number = 11, .priority = 0 };
    rig.quiet.stir();
    _ = rig.cpu.run(100);
    try std.testing.expectEqual(@as(u32, 1), rig.fake.taken);
}

test "only RAM is writable, and flash and the ITCM are readable too" {
    try std.testing.expect(fixed_trip.writable(0x2000_0000, 4));
    try std.testing.expect(fixed_trip.writable(0x2200_0010, 4));
    try std.testing.expect(!fixed_trip.writable(0x2000_FFFE, 4));
    try std.testing.expect(!fixed_trip.writable(0x0200_0000, 4));
    try std.testing.expect(fixed_trip.readable(0x0200_0000, 4));
    try std.testing.expect(fixed_trip.readable(0x0000_0100, 2));
    try std.testing.expect(!fixed_trip.readable(0x4000_0000, 4));
    try std.testing.expect(!fixed_trip.readable(0xE000_E010, 4));
}
