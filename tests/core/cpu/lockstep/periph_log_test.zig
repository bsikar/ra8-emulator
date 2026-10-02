//! Covers src/core/cpu/lockstep/periph_log.zig.
const std = @import("std");
const ra8 = @import("ra8");
const periph_log = ra8.core.cpu.lockstep.periph_log;

const status = 0x4008_0010;

test "a read takes Unicorn's value and counts as matched" {
    var log: periph_log.Log = .{};
    log.begin(true);
    log.noteRead(.{ .address = status, .width = 4, .value = 0x8000_0001 });
    try std.testing.expectEqual(@as(?u32, 0x8000_0001), log.takeRead(status, 4));
    try std.testing.expect(log.verdict() == null);
    try std.testing.expectEqual(@as(u64, 1), log.matched);
}

test "a read at another address or width is a mismatch" {
    var log: periph_log.Log = .{};
    log.begin(true);
    log.noteRead(.{ .address = status, .width = 4, .value = 1 });
    try std.testing.expect(log.takeRead(status, 2) == null);
    const found = log.verdict().?;
    try std.testing.expectEqual(periph_log.Kind.read, found.kind);
    try std.testing.expectEqual(@as(u3, 2), found.ours.?.width);
    try std.testing.expectEqual(@as(u3, 4), found.oracle.?.width);
}

test "a write with a different value is a mismatch, a matching one is not" {
    var log: periph_log.Log = .{};
    log.begin(true);
    log.noteWrite(.{ .address = status, .width = 2, .value = 0xA500 });
    log.takeWrite(.{ .address = status, .width = 2, .value = 0xA500 });
    try std.testing.expect(log.verdict() == null);
    log.begin(true);
    log.noteWrite(.{ .address = status, .width = 2, .value = 0xA500 });
    log.takeWrite(.{ .address = status, .width = 2, .value = 0xA501 });
    try std.testing.expectEqual(@as(u32, 0xA500), log.verdict().?.oracle.?.value);
}

test "an access only Unicorn made is reported, and begin keeps the run count" {
    var log: periph_log.Log = .{};
    log.begin(true);
    log.noteRead(.{ .address = status, .width = 4, .value = 0 });
    _ = log.takeRead(status, 4);
    log.begin(true);
    log.noteWrite(.{ .address = status, .width = 1, .value = 3 });
    const found = log.verdict().?;
    try std.testing.expect(found.ours == null);
    try std.testing.expectEqual(periph_log.Kind.write, found.kind);
    try std.testing.expectEqual(@as(u64, 1), log.matched);
}

test "a mismatch prints both sides" {
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const m: periph_log.Mismatch = .{ .kind = .write, .ours = null, .oracle = .{ .address = status, .width = 1, .value = 3 } };
    try m.write(stream.writer());
    try std.testing.expectEqualStrings("peripheral write: zig none, unicorn 1 byte(s) at 0x40080010 = 0x3", stream.getWritten());
}
