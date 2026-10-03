//! Covers tools/disasm_parity.zig: the sweep, the tally and the report.
const std = @import("std");
const parity = @import("disasm_parity");

/// MOV r0, r1; NOP; MOV.W r0, #1; UMAAL r0, r0, r1, r2 (RdLo == RdHi, which
/// our decode leaves unclaimed); then a wide first halfword with nothing after.
const code = [_]u8{
    0x08, 0x46, 0x00, 0xBF, 0x4F, 0xF0, 0x01, 0x00,
    0xE1, 0xFB, 0x62, 0x00, 0x4F, 0xF0,
};

test "the sweep compares claimed instructions and counts the rest" {
    var tally = parity.Tally.init(std.testing.allocator);
    defer tally.deinit();
    try parity.walk(&tally, 0x0200_0100, &code, std.io.null_writer);
    const sum = tally.total();
    try std.testing.expectEqual(@as(usize, 3), sum.matched);
    try std.testing.expectEqual(@as(usize, 0), sum.mismatched);
    try std.testing.expectEqual(@as(usize, 1), tally.unclaimed);
}

test "the report ends with the total row and the uncompared counts" {
    var tally = parity.Tally.init(std.testing.allocator);
    defer tally.deinit();
    try parity.walk(&tally, 0x0200_0100, &code, std.io.null_writer);
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try parity.report(&tally, stream.writer());
    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "| total | 3 | 0 |") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1 unclaimed by our decode") != null);
}
