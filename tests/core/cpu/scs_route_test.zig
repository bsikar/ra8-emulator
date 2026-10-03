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
    try std.testing.expect(scs_route.wired(&ns, aircr) != null);
    try std.testing.expect(scs_route.wired(null, aircr) == null);
    // ICSR and SHPR3 bank only PendSV while one timer pends SysTick (RA8EMU-439).
    try std.testing.expectEqual(@as(u32, 0x1800_0000), scs_route.wired(&ns, icsr).?.mask);
    try std.testing.expectEqual(@as(u32, 0x00FF_0000), scs_route.wired(&ns, 0xE000_ED20).?.mask);
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

const SysTicks = ra8.periph.scb_bank.SysTicks;
const icsr: u32 = 0xE000_ED04;
const scr: u32 = 0xE000_ED10;
const ccr: u32 = 0xE000_ED14;

fn splitOf(address: u32, view: ra8.periph.scs_alias.View, systicks: SysTicks) scs_route.Split {
    return scs_route.split(.{ .address = address, .view = view }, systicks).?;
}

test "a bit-by-bit register splits over the normal word and its alias copy" {
    const prigroup = splitOf(aircr + 1, .non_secure, .two);
    try std.testing.expectEqual(aircr, prigroup.shared);
    try std.testing.expectEqual(aircr + 0x2_0000, prigroup.non_secure);
    try std.testing.expectEqual(@as(u32, 0x0000_0700), prigroup.mask);
    try std.testing.expectEqual(@as(u32, 0x0007_041A), splitOf(ccr, .secure, .one).mask);
}

test "ICSR banks PENDSV always and PENDST only with two SysTicks" {
    try std.testing.expectEqual(@as(u32, 0x1800_0000), splitOf(icsr, .non_secure, .one).mask);
    try std.testing.expectEqual(@as(u32, 0x1E00_0000), splitOf(icsr, .non_secure, .two).mask);
}

test "unbanked and wholly banked registers have no split" {
    try std.testing.expect(scs_route.split(.{ .address = hfsr, .view = .non_secure }, .two) == null);
    try std.testing.expect(scs_route.split(.{ .address = vtor, .view = .non_secure }, .two) == null);
}

test "a Non-secure read takes the banked bits from the Non-secure copy" {
    const sleep = splitOf(scr, .non_secure, .two);
    try std.testing.expectEqual(@as(u32, 0x0000_0006), sleep.read(0x0000_0014, 0x0000_0002));
    try std.testing.expectEqual(@as(u32, 0x0000_0014), splitOf(scr, .secure, .two).read(0x0000_0014, 0x0000_0002));
}

test "a Non-secure write leaves the Secure banked bits alone" {
    const sleep = splitOf(scr, .non_secure, .two);
    const words = sleep.write(0x0000_0010, 0, 0x0000_0006);
    try std.testing.expectEqual(@as(u32, 0x0000_0014), words.shared);
    try std.testing.expectEqual(@as(u32, 0x0000_0002), words.non_secure);
    const secure = splitOf(scr, .secure, .two).write(0x0000_0010, 0x0000_0002, 0x0000_0004);
    try std.testing.expectEqual(@as(u32, 0x0000_0004), secure.shared);
    try std.testing.expectEqual(@as(u32, 0x0000_0002), secure.non_secure);
}

fn splitRoundTrip(issuer: registry.Issuer) !void {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var periph = registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    var state: Banked = .{};
    var board: BoardBus = .{ .memory = .{ .core = &core }, .periph = &periph, .issuer = issuer, .security = &state };
    const bus = board.view();
    // Secure: SLEEPONEXIT, SLEEPDEEP and SEVONPEND; UNALIGN_TRP; PRIGROUP 5.
    try put(bus, scr, 0x0000_0016);
    try put(bus, ccr, 0x0000_0008);
    try put(bus, aircr, 0x05FA_0500);
    state.current = .non_secure;
    try std.testing.expectEqual(@as(u32, 0x0000_0004), try bus.readWord(scr));
    try std.testing.expectEqual(@as(u32, 0), try bus.readWord(ccr) & 0x8);
    try std.testing.expectEqual(@as(u32, 0), try bus.readWord(aircr) & 0x700);
    try put(bus, scr, 0x0000_0006);
    try bus.write(ccr, &[_]u8{0x08});
    try put(bus, aircr, 0x05FA_0200);
    try std.testing.expectEqual(@as(u32, 0x0000_0006), try bus.readWord(scr));
    try std.testing.expectEqual(@as(u32, 0x8), try bus.readWord(ccr) & 0x8);
    try std.testing.expectEqual(@as(u32, 0x200), try bus.readWord(aircr) & 0x700);
    state.current = .secure;
    try std.testing.expectEqual(@as(u32, 0x0000_0016), try bus.readWord(scr));
    try std.testing.expectEqual(@as(u32, 0x0000_0006), try bus.readWord(scr + 0x2_0000));
    try std.testing.expectEqual(@as(u32, 0x500), try bus.readWord(aircr) & 0x700);
    try put(bus, ccr + 0x2_0000, 0);
    state.current = .non_secure;
    try std.testing.expectEqual(@as(u32, 0), try bus.readWord(ccr) & 0x8);
}

test "SCR, CCR and AIRCR keep a Non-secure copy of their banked bits on CPU0" {
    try splitRoundTrip(.cpu0);
}

test "SCR, CCR and AIRCR keep a Non-secure copy of their banked bits on CPU1" {
    try splitRoundTrip(.cpu1);
}
