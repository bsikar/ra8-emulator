//! Tests for src/core/fault_hook.zig, against a real engine.

const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const memmap = ra8.core.memmap;
const fault_clear = ra8.periph.fault_status.clear;
const Engine = engine.Engine;

const entry: u32 = memmap.sram_base + 0x2000;

/// Run `program` once with r0 pointed at CFSR and r1 holding `value`.
fn storeFrom(program: []const u32, standing: u32, value: u32, clears: *fault_clear.Clears) !Engine {
    var core = try Engine.open();
    errdefer core.close();
    try core.mapBoardRam();
    try core.attachFaultClears(clears);
    try core.writeWord(memmap.scb.cfsr, standing);
    for (program, 0..) |word, i| try core.writeWord(entry + @as(u32, @intCast(i)) * 4, word);
    try core.setRegister(.r0, memmap.scb.cfsr);
    try core.setRegister(.r1, value);
    _ = try core.runChunk(entry, 2, null);
    return core;
}

test "a word store a handler writes back to CFSR clears it at the boundary" {
    var clears = fault_clear.Clears.init();
    // str r1, [r0]; b .
    var core = try storeFrom(&.{0xE7FE_6001}, 0x0000_0082, 0x0000_0082, &clears);
    defer core.close();
    try std.testing.expectEqual(@as(u32, 1), clears.stores);
    try clears.apply(core);
    try std.testing.expectEqual(@as(u32, 0), try core.readWord(memmap.scb.cfsr));
}

test "a byte store to BFSR through the engine clears only BusFault bits" {
    var clears = fault_clear.Clears.init();
    // strb r1, [r0, #1]; b .
    var core = try storeFrom(&.{0xE7FE_7041}, 0x0001_8282, 0x82, &clears);
    defer core.close();
    try clears.apply(core);
    try std.testing.expectEqual(@as(u32, 0x0001_0082), try core.readWord(memmap.scb.cfsr));
}

test "a store to SFSR through the engine is latched and clears at the boundary" {
    var clears = fault_clear.Clears.init();
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.attachFaultClears(&clears);
    try core.writeWord(fault_clear.sfsr, 0x0000_0048);
    // str r1, [r0]; b .
    try core.writeWord(entry, 0xE7FE_6001);
    try core.setRegister(.r0, fault_clear.sfsr);
    try core.setRegister(.r1, 0x0000_0008);
    _ = try core.runChunk(entry, 2, null);
    try std.testing.expectEqual(@as(u32, 1), clears.stores);
    try clears.apply(core);
    try std.testing.expectEqual(@as(u32, 0x0000_0040), try core.readWord(fault_clear.sfsr));
}
