//! Covers src/core/cpu/lockstep/memory_diff.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;
const writes = ra8.core.cpu.lockstep.writes;
const memory_diff = ra8.core.cpu.lockstep.memory_diff;

fn store(address: u32, bytes: []const u8) writes.Write {
    var made: writes.Write = .{ .address = address, .len = @intCast(bytes.len) };
    @memcpy(made.bytes[0..bytes.len], bytes);
    return made;
}

test "stores Unicorn's memory also holds match" {
    var theirs = try Engine.open();
    defer theirs.close();
    try theirs.mapBoardRam();
    try theirs.write(memmap.sram_base, &.{ 1, 2, 3, 4 });
    const made = [_]writes.Write{store(memmap.sram_base, &.{ 1, 2, 3, 4 })};
    try std.testing.expect((try memory_diff.first(&made, theirs)) == null);
}

test "the first store Unicorn disagrees with is reported with both bytes" {
    var theirs = try Engine.open();
    defer theirs.close();
    try theirs.mapBoardRam();
    try theirs.write(memmap.sram_base + 4, &.{ 0xAA, 0xBB });
    const made = [_]writes.Write{
        store(memmap.sram_base + 0, &.{0}),
        store(memmap.sram_base + 4, &.{ 0xAA, 0xBC }),
    };
    const found = (try memory_diff.first(&made, theirs)).?;
    try std.testing.expectEqual(memmap.sram_base + 4, found.address);
    var buffer: [96]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try found.write(stream.writer());
    var want: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "memory at 0x{X:0>8}: zig AABC, unicorn AABB", .{memmap.sram_base + 4});
    try std.testing.expectEqualStrings(line, stream.getWritten());
}
