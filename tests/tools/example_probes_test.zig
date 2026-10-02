//! The probe verdicts read --dump-sym lines the way the report prints them.
const std = @import("std");
const table = @import("example_table");
const probes = table.probes;

const healthy =
    \\  dump-sym      : g_ns_pingpong_match @0x22100000 = 38 (0x00000026)
    \\  dump-sym      : g_ns_pingpong_mismatch @0x22100004 = 0 (0x00000000)
    \\
;

const mismatched =
    \\  dump-sym      : g_ns_pingpong_match @0x22100000 = 38 (0x00000026)
    \\  dump-sym      : g_ns_pingpong_mismatch @0x22100004 = 2 (0x00000002)
    \\
;

const stalled =
    \\  dump-sym      : g_ns_pingpong_match @0x22100000 = 1 (0x00000001)
    \\  dump-sym      : g_ns_pingpong_mismatch @0x22100004 = 0 (0x00000000)
    \\
;

const unresolved =
    \\  dump-sym      : g_ns_pingpong_match <unresolved>
    \\  dump-sym      : g_ns_pingpong_mismatch @0x22100004 = 0 (0x00000000)
    \\
;

fn ipc() probes.Probe {
    return probes.find("cpu1_pingpong_ipc.elf").?;
}

test "both ping-pongs carry a probe and a lone image does not" {
    try std.testing.expect(probes.find("cpu1_pingpong.elf") != null);
    try std.testing.expectEqualStrings("g_ns_pingpong_match", ipc().symbol);
    try std.testing.expectEqual(@as(?probes.Probe, null), probes.find("threadx_blink.elf"));
}

test "a dump-sym value is read by its exact name" {
    try std.testing.expectEqual(@as(?u32, 38), probes.dumped(healthy, "g_ns_pingpong_match"));
    try std.testing.expectEqual(@as(?u32, 0), probes.dumped(healthy, "g_ns_pingpong_mismatch"));
    try std.testing.expectEqual(@as(?u32, null), probes.dumped(healthy, "g_ns_pingpong"));
    try std.testing.expectEqual(@as(?u32, null), probes.dumped(unresolved, "g_ns_pingpong_match"));
}

test "round-trips with no mismatch pass, a mismatch or a stall fails" {
    try std.testing.expectEqual(probes.Judgement.pass, probes.judge(ipc(), healthy));
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(ipc(), mismatched));
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(ipc(), stalled));
    try std.testing.expectEqual(probes.Judgement.unknown, probes.judge(ipc(), unresolved));
}

test "a probe verdict decides a row with no console, a fault still fails it" {
    var row = table.parse(healthy);
    row.probe = probes.judge(ipc(), healthy);
    try std.testing.expectEqual(table.Verdict.pass, row.verdict());
    row.stopped = "pc 0x00000000";
    try std.testing.expectEqual(table.Verdict.fail, row.verdict());
}
