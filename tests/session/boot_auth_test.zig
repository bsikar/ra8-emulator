//! RA8EMU-1271: execute current signed firmware in ReleaseFast; README pins provenance.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const fixture = @import("boot_auth_fixture.zig");

fn rejected(case: fixture.Case, expected: u16) !void {
    const outcome = try fixture.boot(case);
    try std.testing.expect(outcome.crc_a and outcome.crc_b);
    try std.testing.expectEqual(@as(?u16, expected), outcome.gate_result);
    const selected: ra8.session.boot_slots.Which = if (case.seq_a >= case.seq_b) .a else .b;
    try std.testing.expectEqual(@as(?ra8.session.boot_slots.Which, selected), outcome.gate_slot);
    try std.testing.expectEqual(@as(u32, 0), outcome.marker);
    try std.testing.expect(outcome.dfu);
}

test "current firmware authentic A and B controls execute distinct payload markers" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    const a = try fixture.boot(.{ .seq_a = 3 });
    try std.testing.expect(a.crc_a and a.crc_b);
    try std.testing.expectEqual(@as(?ra8.session.boot_slots.Which, .a), a.gate_slot);
    try std.testing.expectEqual(@as(?u16, 0), a.gate_result);
    try std.testing.expectEqual(fixture.marker_a, a.marker);
    try std.testing.expect(!a.dfu);
    const b = try fixture.boot(.{});
    try std.testing.expect(b.crc_a and b.crc_b);
    try std.testing.expectEqual(@as(?ra8.session.boot_slots.Which, .b), b.gate_slot);
    try std.testing.expectEqual(@as(?u16, 0), b.gate_result);
    try std.testing.expectEqual(fixture.marker_b, b.marker);
    try std.testing.expect(!b.dfu);
}

test "body tampering with recomputed outer CRC is rejected by the firmware digest gate" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    try rejected(.{ .fault_b = .body }, 0x502);
    try rejected(.{ .fault_a = .body, .seq_a = 3 }, 0x502);
}

test "invalid ECDSA and wrong root signatures never launch despite valid body CRC" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    // backend_psa.verifyHash maps PSA_ERROR_INVALID_SIGNATURE to 0x405.
    for ([_]fixture.Fault{ .signature, .wrong_root }) |fault| {
        try rejected(.{ .fault_b = fault }, 0x405);
        try rejected(.{ .fault_a = fault, .seq_a = 3 }, 0x405);
    }
}

test "forged signed version metadata is rejected rather than authenticated by outer CRC" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    try rejected(.{ .fault_b = .version }, 0x405);
}

test "malformed ROT1 magic body length and signature length fail firmware screening" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    try rejected(.{ .fault_b = .magic }, 0x501);
    try rejected(.{ .fault_b = .format_version }, 0x501);
    try rejected(.{ .fault_b = .body_length }, 0x105);
    try rejected(.{ .fault_b = .sig_length }, 0x105);
}

test "a truncated ROT1 signature tail is rejected by the firmware verifier" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    try rejected(.{ .fault_b = .truncated }, 0x405);
}

test "newer CRC valid unauthentic B enters DFU instead of falling back to authentic A" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    const outcome = try fixture.boot(.{ .fault_b = .signature });
    try std.testing.expect(outcome.crc_a and outcome.crc_b);
    try std.testing.expectEqual(@as(?ra8.session.boot_slots.Which, .b), outcome.gate_slot);
    try std.testing.expect(outcome.gate_result != null and outcome.gate_result.? != 0);
    try std.testing.expectEqual(@as(u32, 0), outcome.marker);
    try std.testing.expect(outcome.dfu);
}

test "neither authentic slot and explicit DFU request have deterministic recovery" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    const neither = try fixture.boot(.{ .fault_a = .signature, .fault_b = .signature });
    try std.testing.expect(neither.crc_a and neither.crc_b);
    try std.testing.expectEqual(@as(?u16, 0x405), neither.gate_result);
    try std.testing.expectEqual(@as(u32, 0), neither.marker);
    try std.testing.expect(neither.dfu);
    const requested = try fixture.boot(.{ .trigger = true });
    try std.testing.expect(requested.crc_a and requested.crc_b);
    try std.testing.expectEqual(@as(?u16, null), requested.gate_result);
    try std.testing.expectEqual(@as(u32, 0), requested.marker);
    try std.testing.expect(requested.dfu);
}
