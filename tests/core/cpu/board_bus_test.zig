//! Covers src/core/cpu/board_bus.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const registry = ra8.periph.registry;
const BoardBus = ra8.core.cpu.board_bus.BoardBus;
const Engine = ra8.core.engine.Engine;

/// One register block that remembers the last access it saw.
const Probe = struct {
    address: u32 = 0,
    width: u3 = 0,
    value: u32 = 0,

    fn read(context: *anyopaque, address: u32, width: u3) u32 {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.address = address;
        self.width = width;
        return 0xA1B2_C3D4;
    }

    fn write(context: *anyopaque, address: u32, width: u3, value: u32) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.address = address;
        self.width = width;
        self.value = value;
    }
};

const at = registry.base + 0x8_0000;

fn attach(periph: *registry.Bus, probe: *Probe) !void {
    try periph.add(.{
        .name = "probe",
        .base = at,
        .size = 0x100,
        .context = probe,
        .readFn = Probe.read,
        .writeFn = Probe.write,
    });
}

test "a halfword store in the peripheral window reaches the peripheral" {
    var core = try Engine.open();
    defer core.close();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var probe: Probe = .{};
    try attach(&periph, &probe);
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph };
    try board.view().write(at + 4, &[_]u8{ 0x1A, 0x80 });
    try std.testing.expectEqual(@as(u32, at + 4), probe.address);
    try std.testing.expectEqual(@as(u3, 2), probe.width);
    try std.testing.expectEqual(@as(u32, 0x801A), probe.value);
}

test "a read in the Non-secure alias comes back from the same peripheral" {
    var core = try Engine.open();
    defer core.close();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var probe: Probe = .{};
    try attach(&periph, &probe);
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph };
    try std.testing.expectEqual(@as(u32, 0xA1B2_C3D4), try board.view().readWord(at + registry.ns_offset));
    try std.testing.expectEqual(@as(u3, 4), probe.width);
    var byte: [1]u8 = undefined;
    try board.view().read(at, &byte);
    try std.testing.expectEqual(@as(u8, 0xD4), byte[0]);
}

test "memory outside the windows still goes to the engine" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph };
    try board.view().write(memmap.sram_base, &[_]u8{ 1, 2, 3, 4 });
    try std.testing.expectEqual(@as(u32, 0x0403_0201), try core.readWord(memmap.sram_base));
    try std.testing.expectEqual(@as(u32, 0), periph.counters.writes);
}

test "an access wider than one register is refused" {
    var core = try Engine.open();
    defer core.close();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph };
    var wide: [8]u8 = undefined;
    try std.testing.expectError(error.Unmapped, board.view().read(at, &wide));
    try std.testing.expect(!BoardBus.inWindow(registry.base + registry.size - 2, 4));
    try std.testing.expect(BoardBus.inWindow(registry.ns_base, 4));
}

fn storeWord(board: *BoardBus, address: u32, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try board.view().write(address, &bytes);
}

test "SAU RBAR and RLAR bank through RNR on the Zig bus" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var partitions = ra8.periph.sau.Sau.init();
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph, .scs = .{ .partitions = &partitions } };
    try storeWord(&board, memmap.sau.rnr, 1);
    try storeWord(&board, memmap.sau.rbar, 0x0200_0000);
    try storeWord(&board, memmap.sau.rlar, 0x0207_FFE1);
    try storeWord(&board, memmap.sau.rnr, 0);
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.sau.rbar));
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.sau.rlar));
    try storeWord(&board, memmap.sau.rnr, 1);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), try board.view().readWord(memmap.sau.rbar));
    try std.testing.expectEqual(@as(u32, 0x0207_FFE1), try board.view().readWord(memmap.sau.rlar));
    try std.testing.expectEqual(@as(u32, 2), partitions.banked);
}

test "a bus with no SAU leaves the window as plain RAM" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph };
    try storeWord(&board, memmap.sau.rbar, 0x0200_0000);
    try storeWord(&board, memmap.sau.rnr, 1);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), try board.view().readWord(memmap.sau.rbar));
}

test "MPU pairs bank through RNR on the Zig bus, aliases included" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var regions = ra8.periph.mpu.Mpu.init();
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph, .scs = .{ .regions = &regions } };
    try storeWord(&board, memmap.mpu.rnr, 4);
    try storeWord(&board, memmap.mpu.rbar, 0x2200_0000);
    try storeWord(&board, memmap.mpu.rlar_a1, 0x2207_FFE1);
    try storeWord(&board, memmap.mpu.rnr, 0);
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.mpu.rbar));
    try std.testing.expectEqual(@as(u32, 0), try board.view().readWord(memmap.mpu.rlar_a1));
    try storeWord(&board, memmap.mpu.rnr, 4);
    try std.testing.expectEqual(@as(u32, 0x2200_0000), try board.view().readWord(memmap.mpu.rbar));
    try std.testing.expectEqual(@as(u32, 0x2207_FFE1), try board.view().readWord(memmap.mpu.rlar_a1));
}

test "CFSR and HFSR clear the bits a store writes ones to" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var clears = ra8.core.cpu.board_bus.fault_clear.Clears.init();
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph, .scs = .{ .clears = &clears } };
    try core.writeWord(memmap.scb.cfsr, 0x0001_0182);
    try storeWord(&board, memmap.scb.cfsr, 0x0000_0100);
    try std.testing.expectEqual(@as(u32, 0x0001_0082), try board.view().readWord(memmap.scb.cfsr));
    try board.view().write(memmap.scb.cfsr + 2, &[_]u8{ 0x01, 0x00 });
    try std.testing.expectEqual(@as(u32, 0x0000_0082), try board.view().readWord(memmap.scb.cfsr));
    try core.writeWord(memmap.scb.hfsr, 0x4000_0002);
    try storeWord(&board, memmap.scb.hfsr, 0x4000_0000);
    try std.testing.expectEqual(@as(u32, 0x0000_0002), try board.view().readWord(memmap.scb.hfsr));
    try std.testing.expectEqual(@as(u32, 3), clears.stores);
}
