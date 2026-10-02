//! Tests for src/periph/scs_alias.zig.

const std = @import("std");
const ra8 = @import("ra8");
const alias = ra8.periph.scs_alias;

const vtor: u32 = 0xE000_ED08;
const vtor_ns: u32 = 0xE002_ED08;

fn target(address: u32, secure: bool) alias.Target {
    return switch (alias.route(address, secure)) {
        .register => |t| t,
        else => unreachable,
    };
}

test "the alias windows sit 0x20000 above the normal ones" {
    try std.testing.expectEqual(@as(u32, 0xE002_E000), alias.scs_ns.first);
    try std.testing.expectEqual(@as(u32, 0xE002_EFFF), alias.scs_ns.last);
    try std.testing.expectEqual(@as(u32, 0xE002_ED00), alias.scb_ns.first);
    try std.testing.expectEqual(@as(u32, 0xE002_ED8F), alias.scb_ns.last);
}

test "the normal window answers in the state of the caller" {
    try std.testing.expectEqual(alias.View.secure, target(vtor, true).view);
    try std.testing.expectEqual(alias.View.non_secure, target(vtor, false).view);
    try std.testing.expectEqual(vtor, target(vtor, false).address);
}

test "Secure code reaches the Non-secure bank through the alias" {
    const t = target(vtor_ns, true);
    try std.testing.expectEqual(vtor, t.address);
    try std.testing.expectEqual(alias.View.non_secure, t.view);
}

test "Non-secure code on the alias is reported, not resolved" {
    const r = alias.route(vtor_ns, false);
    try std.testing.expectEqual(vtor, r.alias_from_non_secure);
}

test "the window edges are inclusive and nothing past them routes" {
    try std.testing.expectEqual(@as(u32, 0xE000_E000), target(0xE002_E000, true).address);
    try std.testing.expectEqual(@as(u32, 0xE000_EFFF), target(0xE002_EFFF, true).address);
    try std.testing.expect(alias.route(0xE002_DFFF, true) == .outside);
    try std.testing.expect(alias.route(0xE002_F000, true) == .outside);
    try std.testing.expect(alias.route(0xE000_DFFF, false) == .outside);
}

test "isScb takes either window and nothing beside them" {
    try std.testing.expect(alias.isScb(vtor));
    try std.testing.expect(alias.isScb(vtor_ns));
    try std.testing.expect(!alias.isScb(0xE000_ED90));
    try std.testing.expect(!alias.isScb(0xE002_ECFF));
}
