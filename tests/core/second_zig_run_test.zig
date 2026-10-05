//! Tests for src/core/second_zig_run.zig: CPU1's turns under --cpu zig
//! (RA8EMU-234).
const std = @import("std");
const ra8 = @import("ra8");
const second_core = ra8.core.second_core;
const Driver = second_core.zig_run.Driver;
const Store = ra8.core.cpu.memory.store.Store;
const Guest = ra8.core.cpu.memory.guest.Guest;
const Units = second_core.zig.Units;
const memmap = ra8.core.memmap;
const Board = ra8.board.Board;

const vectors: u32 = memmap.sram_base + 0x1000;
const code: u32 = vectors + 0x200;
const stack: u32 = vectors + 0x800;

/// A driver whose CPU1 runs `program` from reset, built the way `open`
/// builds it but from words in its own store instead of an ELF on disk.
fn bring(driver: *Driver, board: *Board, program: []const u16) !void {
    driver.second = .{ .state = .{ .vector_base = vectors } };
    driver.store = try Store.init(null);
    errdefer driver.close();
    const memory: Guest = .{ .store = &driver.store.? };
    try memory.writeWord(vectors, stack);
    try memory.writeWord(vectors + 4, code | 1);
    for (program, 0..) |half, i| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, half, .little);
        try memory.write(code + @as(u32, @intCast(2 * i)), &bytes);
    }
    try driver.core.openOn(memory, Units.of(&driver.second), &board.bus);
}

test "a round runs CPU1's share on its Zig core and counts it by core rate" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    // B . : a core that runs every instruction it is given.
    try bring(&driver, &board, &.{0xE7FE});
    defer driver.close();

    // No divider word on the board: CPU1 runs as many as CPU0 did.
    driver.round(100);
    driver.round(100);
    try std.testing.expectEqual(@as(usize, 2), driver.second.state.turns);
    try std.testing.expectEqual(@as(usize, 200), driver.second.state.ran);
    try std.testing.expectEqual(code, driver.second.state.pc);
    try std.testing.expectEqual(@as(?ra8.core.fault.Fault, null), driver.second.state.fault);
}

test "a CPU1 that stops is reported where it stopped and takes no more turns" {
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var driver: Driver = undefined;
    // MOVS r0, #1, then UDF with no fault handlers in the table: the
    // UsageFault escalates and the core cannot carry on.
    try bring(&driver, &board, &.{ 0x2001, 0xDE00 });
    defer driver.close();

    driver.round(50);
    const fault = driver.second.state.fault orelse return error.NoFault;
    try std.testing.expectEqual(driver.second.state.pc, fault.pc);
    try std.testing.expect(fault.detail.len > 0);
    const ran = driver.second.state.ran;
    try std.testing.expect(ran < 50);
    driver.round(50);
    try std.testing.expectEqual(@as(usize, 1), driver.second.state.turns);
    try std.testing.expectEqual(ran, driver.second.state.ran);
}
