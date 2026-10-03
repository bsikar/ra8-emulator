//! Tests for src/core/mpu_ns_hook.zig: stores through the MPU_NS alias file
//! into the Non-secure table on the Unicorn backend, and the normal window
//! leaves it alone.
const std = @import("std");
const ra8 = @import("ra8");
const hook = ra8.core.mpu_hook.ns;
const Mpu = ra8.periph.mpu.Mpu;

const rnr: u32 = 0xE000_ED98;
const rbar: u32 = 0xE000_ED9C;
const rlar: u32 = 0xE000_EDA0;
const alias: u32 = 0x2_0000;

test "the hook watches the MPU window's alias, TYPE through MAIR1" {
    try std.testing.expectEqual(@as(u64, 0xE002_ED90), hook.window.first);
    try std.testing.expectEqual(@as(u64, 0xE002_EDC7), hook.window.last);
}

test "a region programmed through the alias lands in the Non-secure table only" {
    var secure = Mpu.init();
    var non_secure = Mpu.init();
    try std.testing.expect(hook.file(&non_secure, rnr + alias, 1));
    try std.testing.expect(!hook.file(&non_secure, rbar + alias, 0x2000_0000));
    try std.testing.expect(!hook.file(&non_secure, rlar + alias, 0x2000_7FE1));
    try std.testing.expectEqual(@as(u32, 2), non_secure.banked);
    try std.testing.expectEqual(@as(u32, 0), secure.banked);
    const words = hook.selected(&non_secure);
    try std.testing.expectEqual(rbar + alias, words[0].address);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), words[0].value);
    try std.testing.expectEqual(rlar + alias, words[1].address);
    try std.testing.expectEqual(@as(u32, 0x2000_7FE1), words[1].value);
    _ = &secure;
}

test "a store to the normal window files nothing in the Non-secure table" {
    var non_secure = Mpu.init();
    try std.testing.expect(!hook.file(&non_secure, rnr, 1));
    try std.testing.expect(!hook.file(&non_secure, rbar, 0x2000_0000));
    try std.testing.expectEqual(@as(u32, 0), non_secure.banked);
}

test "RNR moved through the alias selects the Non-secure region it names" {
    var non_secure = Mpu.init();
    _ = hook.file(&non_secure, rnr + alias, 2);
    _ = hook.file(&non_secure, rbar + alias, 0x3000_0000);
    _ = hook.file(&non_secure, rlar + alias, 0x3000_0FE1);
    try std.testing.expect(hook.file(&non_secure, rnr + alias, 0));
    try std.testing.expectEqual(@as(u32, 0), hook.selected(&non_secure)[0].value);
    try std.testing.expect(hook.file(&non_secure, rnr + alias, 2));
    try std.testing.expectEqual(@as(u32, 0x3000_0000), hook.selected(&non_secure)[0].value);
}
