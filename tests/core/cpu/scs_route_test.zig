//! Covers src/core/cpu/scs_route.zig: which PPB word an SCS access lands on
//! for each Security state, and the same through each core's BoardBus.

const std = @import("std");
const ra8 = @import("ra8");
const scs_route = ra8.core.cpu.board_bus.scs_route;
const Banked = ra8.core.banked.Banked;
const registry = ra8.periph.registry;
const BoardBus = ra8.core.cpu.board_bus.BoardBus;
const Engine = ra8.core.engine.Engine;

const vtor: u32 = 0xE000_ED08;
const vtor_alias: u32 = 0xE002_ED08;
const hfsr: u32 = 0xE000_ED2C;
const aircr: u32 = 0xE000_ED0C;

fn expectAt(expected: u32, landing: scs_route.Landing) !void {
    try std.testing.expectEqual(scs_route.Landing{ .at = expected }, landing);
}

test "Secure code reaches its own copy and the Non-secure one through the alias" {
    const secure: Banked = .{};
    try expectAt(vtor, scs_route.land(&secure, vtor));
    try expectAt(vtor_alias, scs_route.land(&secure, vtor_alias));
    try expectAt(vtor, scs_route.land(null, vtor));
}

test "Non-secure code on the normal window reaches the Non-secure copy" {
    const ns: Banked = .{ .current = .non_secure };
    try expectAt(vtor_alias, scs_route.land(&ns, vtor));
    try expectAt(vtor_alias + 1, scs_route.land(&ns, vtor + 1));
}

test "Non-secure code on the alias window gets RES0" {
    const ns: Banked = .{ .current = .non_secure };
    try std.testing.expectEqual(scs_route.Landing.res0, scs_route.land(&ns, vtor_alias));
}

test "an unbanked register has one word from either state and either window" {
    const ns: Banked = .{ .current = .non_secure };
    const secure: Banked = .{};
    try expectAt(hfsr, scs_route.land(&ns, hfsr));
    try expectAt(hfsr, scs_route.land(&secure, hfsr + 0x2_0000));
}

test "a bit-by-bit register and anything outside the SCS keep their address" {
    const ns: Banked = .{ .current = .non_secure };
    try expectAt(aircr, scs_route.land(&ns, aircr));
    try expectAt(0x2000_0000, scs_route.land(&ns, 0x2000_0000));
}

fn put(bus: anytype, address: u32, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try bus.write(address, &bytes);
}

fn roundTrip(issuer: registry.Issuer) !void {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var state: Banked = .{};
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph, .issuer = issuer, .security = &state };
    const bus = board.view();
    try put(bus, vtor, 0x0200_0000);
    try put(bus, vtor_alias, 0x0210_0000);
    state.current = .non_secure;
    try std.testing.expectEqual(@as(u32, 0x0210_0000), try bus.readWord(vtor));
    try put(bus, vtor, 0x0220_0000);
    try std.testing.expectEqual(@as(u32, 0), try bus.readWord(vtor_alias));
    try put(bus, vtor_alias, 0xDEAD_BEEF);
    state.current = .secure;
    try std.testing.expectEqual(@as(u32, 0x0200_0000), try bus.readWord(vtor));
    try std.testing.expectEqual(@as(u32, 0x0220_0000), try bus.readWord(vtor_alias));
}

test "VTOR round trip from each state and through the alias on CPU0" {
    try roundTrip(.cpu0);
}

test "VTOR round trip from each state and through the alias on CPU1" {
    try roundTrip(.cpu1);
}
