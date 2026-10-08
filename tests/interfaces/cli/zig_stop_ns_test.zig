//! RA8EMU-651: `--stop-sym` finds a counter the `--ns` image carries, as
//! `--dump-sym` does. Uses the TrustZone pair in tests/fixtures/trustzone,
//! whose Non-secure image keeps g_tz_nsc_cgc_usb_match at 0x3210DE10.
const std = @import("std");
const ra8 = @import("ra8");

const zig_stop = ra8.board.zig_run.stop_sym;
const secure_bytes = @embedFile("../../fixtures/trustzone/tz_nsc_cgc_usb.elf");
const ns_bytes = @embedFile("../../fixtures/trustzone/tz_nsc_cgc_usb_ns.elf");
const counter = "g_tz_nsc_cgc_usb_match";

test "a --stop-sym name only the --ns image carries resolves there" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "ns.elf", .data = ns_bytes });
    const ns_path = try tmp.dir.realPathFileAlloc(std.testing.io, "ns.elf", std.testing.allocator);
    defer std.testing.allocator.free(ns_path);
    const image = try ra8.core.elf.Image.init(secure_bytes);
    const options: ra8.core.cli.Options = .{ .path = "s.elf", .ns_path = ns_path, .stop_symbol = counter, .stop_at = 50 };
    const watch = zig_stop.resolve(image, options) orelse return error.TestExpectedStop;
    try std.testing.expectEqual(@as(u32, 0x3210_DE10), watch.address);
    try std.testing.expectEqual(@as(u32, 50), watch.reaches);
}

test "without --ns a Non-secure name stays unresolved" {
    const image = try ra8.core.elf.Image.init(secure_bytes);
    const options: ra8.core.cli.Options = .{ .path = "s.elf", .stop_symbol = counter, .stop_at = 50 };
    try std.testing.expect(zig_stop.resolve(image, options) == null);
}
