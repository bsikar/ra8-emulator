//! Covers src/core/cpu/exception/quiet_source.zig.
const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("ram.zig");
const Fake = @import("fake_source.zig").Fake;
const QuietSource = ra8.core.cpu.exception.quiet_source.QuietSource;
const bus = ra8.core.cpu.bus;

const systick: ra8.core.cpu.exception.active.Entry = .{ .number = 15, .priority = 0x80 };

fn settled(ram: *fixture.Ram, fake: *Fake) QuietSource {
    fake.pending = null;
    return .{ .inner = fake.source(), .memory = ram.view() };
}

test "a nothing-pending answer stands until something stirs" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    const source = quiet.source();
    try std.testing.expect((try source.winner(quiet.bus())) == null);
    fake.pending = systick;
    try std.testing.expect((try source.winner(quiet.bus())) == null);
    quiet.stir();
    try std.testing.expectEqual(@as(u9, 15), (try source.winner(quiet.bus())).?.number);
}

test "a pending answer is never held" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{ .pending = systick };
    var quiet: QuietSource = .{ .inner = fake.source(), .memory = ram.view() };
    const source = quiet.source();
    try std.testing.expect((try source.winner(quiet.bus())) != null);
    fake.pending = null;
    try std.testing.expect((try source.winner(quiet.bus())) == null);
}

test "RAM traffic leaves it settled, system space stirs it" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    const source = quiet.source();
    const memory = quiet.bus();
    _ = try source.winner(memory);
    fake.pending = systick;
    try memory.write(fixture.base + 0x200, &.{ 1, 2, 3, 4 });
    _ = try memory.readWord(fixture.base + 0x200);
    try std.testing.expect((try source.winner(memory)) == null);
    _ = try memory.readWord(fixture.scs + 0xD04);
    try std.testing.expect((try source.winner(memory)) != null);
}

test "the bus it hands out reaches the run's memory" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    try quiet.bus().write(fixture.scs + 0xD04, &.{ 0, 0, 0, 0x10 });
    try std.testing.expectEqual(@as(u32, 0x1000_0000), ram.word(fixture.scs + 0xD04));
    try std.testing.expectEqual(@as(u32, 0x1000_0000), try quiet.bus().readWord(fixture.scs + 0xD04));
}

test "the bus it hands out preserves the direct-memory view" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    var flash = [_]u8{ 1, 2, 3, 4 };
    var direct: bus.DirectMemory = .{ .flash = &flash, .enabled = true };
    quiet.memory.direct = &direct;

    try std.testing.expect(quiet.bus().direct == &direct);
    try std.testing.expectEqual(@as(u32, 0x0403_0201), try quiet.bus().readWord(ra8.core.memmap.mram_base));
}

test "taking or leaving an exception stirs and forwards" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    const source = quiet.source();
    _ = try source.winner(ram.view());
    try source.taken(ram.view(), 15);
    try std.testing.expect(!quiet.settled);
    _ = try source.winner(ram.view());
    try source.returned(ram.view(), 15);
    try std.testing.expect(!quiet.settled);
    try std.testing.expectEqual(@as(u32, 1), fake.taken);
    try std.testing.expectEqual(@as(?u9, 15), fake.last_returned);
}

test "each run of the core starts by stirring" {
    var ram: fixture.Ram = .{};
    var fake: Fake = .{};
    var quiet = settled(&ram, &fake);
    var cpu = try fixture.boot(&ram);
    ram.putHalf(fixture.code, 0xBF00);
    cpu.quiet = &quiet;
    quiet.settled = true;
    _ = cpu.run(0);
    try std.testing.expect(!quiet.settled);
}
