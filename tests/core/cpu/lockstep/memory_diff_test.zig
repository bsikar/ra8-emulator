//! Covers src/core/cpu/lockstep/memory_diff.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;
const writes = ra8.core.cpu.lockstep.writes;
const memory_diff = ra8.core.cpu.lockstep.memory_diff;

/// Only a write-one-to-clear store reads back through the Zig side's bus;
/// the stores here are plain RAM, so any bus will do.
fn plain(core: *Engine) ra8.core.cpu.bus.Bus {
    const held = std.heap.page_allocator.create(ra8.core.cpu.engine_bus.EngineBus) catch unreachable;
    held.* = .{ .core = core };
    return held.view();
}

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
    try std.testing.expect((try memory_diff.first(&made, &.{}, theirs, plain(&theirs))) == null);
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
    const found = (try memory_diff.first(&made, &.{}, theirs, plain(&theirs))).?;
    try std.testing.expectEqual(memmap.sram_base + 4, found.address);
    var buffer: [96]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try found.write(stream.writer());
    var want: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "memory at 0x{X:0>8}: zig AABC, unicorn AABB", .{memmap.sram_base + 4});
    try std.testing.expectEqualStrings(line, stream.getWritten());
}

test "a store into CFSR is checked by what each side now holds" {
    var theirs = try Engine.open();
    defer theirs.close();
    try theirs.mapBoardRam();
    var mine = try Engine.open();
    defer mine.close();
    try mine.mapBoardRam();
    for ([_]*Engine{ &mine, &theirs }) |core| try core.write(memmap.scb.cfsr, &.{ 0x00, 0x01, 0x00, 0x00 });
    // The store was 0x02; both sides kept 0x100 once the clear settled.
    const made = [_]writes.Write{store(memmap.scb.cfsr, &.{ 0x02, 0x00, 0x00, 0x00 })};
    try std.testing.expect((try memory_diff.first(&made, &.{}, theirs, plain(&mine))) == null);
    try std.testing.expect(memory_diff.settles(memmap.scb.hfsr + 3));
    try std.testing.expect(!memory_diff.settles(memmap.sram_base));
}

test "a Unicorn-only store reports its address and both byte values" {
    var ours = try Engine.open();
    defer ours.close();
    var theirs = try Engine.open();
    defer theirs.close();
    try ours.mapBoardRam();
    try theirs.mapBoardRam();
    try theirs.write(memmap.sram_base + 8, &.{ 0x34, 0x12 });
    const oracle_made = [_]writes.Write{store(memmap.sram_base + 8, &.{ 0x34, 0x12 })};
    const found = (try memory_diff.first(&.{}, &oracle_made, theirs, plain(&ours))).?;
    try std.testing.expectEqual(memmap.sram_base + 8, found.address);
    var buffer: [96]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try found.write(stream.writer());
    var want: [96]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "memory at 0x{X:0>8}: zig 0000, unicorn 3412", .{memmap.sram_base + 8});
    try std.testing.expectEqualStrings(line, stream.getWritten());
}
