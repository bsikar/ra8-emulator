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

const booted =
    \\  dump-sym      : g_sbns_ns_alive @0x32100090 = 4021 (0x00000FB5)
    \\  dump-sym      : g_sbns_denied @0x22001064 = 0 (0x00000000)
    \\
;

const denied =
    \\  dump-sym      : g_sbns_ns_alive @0x32100090 = 0 (0x00000000)
    \\  dump-sym      : g_sbns_denied @0x22001064 = 1 (0x00000001)
    \\
;

test "secure boot passes on the Non-Secure heartbeat and fails on a denied handover" {
    const boot = probes.find("secure_boot_ns_hil.elf").?;
    try std.testing.expectEqualStrings("g_sbns_ns_alive", boot.symbol);
    try std.testing.expectEqualStrings("g_sbns_denied", boot.failure);
    try std.testing.expectEqual(probes.Judgement.pass, probes.judge(boot, booted));
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(boot, denied));
    try std.testing.expectEqual(@as(?probes.Probe, null), probes.find("secure_boot_ns_hil_ns.elf"));
}

const ticking =
    \\  dump-sym      : _tx_timer_system_clock @0x321020B0 = 2999 (0x00000BB7)
    \\  dump-sym      : g_tz_threadx_demo_fallback_count @0x22001850 = 0 (0x00000000)
    \\
;

const fell_back =
    \\  dump-sym      : _tx_timer_system_clock @0x321020B0 = 0 (0x00000000)
    \\  dump-sym      : g_tz_threadx_demo_fallback_count @0x22001850 = 1 (0x00000001)
    \\
;

test "tz_threadx_demo passes on the Non-Secure tick and fails on the secure fallback" {
    const demo = probes.find("tz_threadx_demo.elf").?;
    try std.testing.expectEqualStrings("_tx_timer_system_clock", demo.symbol);
    try std.testing.expectEqual(probes.Judgement.pass, probes.judge(demo, ticking));
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(demo, fell_back));
    try std.testing.expectEqual(@as(?probes.Probe, null), probes.find("tz_threadx_demo_ns.elf"));
}

const looping =
    \\  dump-sym      : g_tz_usb_host_rounds_ok @0x32111260 = 358 (0x00000166)
    \\  dump-sym      : g_tz_nsc_cgc_usb_mismatch @0x32108F00 = 0 (0x00000000)
    \\
;

const not_enumerated =
    \\  dump-sym      : g_tz_usb_host_rounds_ok @0x32111260 = 0 (0x00000000)
    \\  dump-sym      : g_tz_nsc_cgc_usb_mismatch @0x32108F00 = 0 (0x00000000)
    \\
;

const veneer_error =
    \\  dump-sym      : g_tz_usb_host_rounds_ok @0x32111260 = 358 (0x00000166)
    \\  dump-sym      : g_tz_nsc_cgc_usb_mismatch @0x32108F00 = 1 (0x00000001)
    \\
;

test "tz_nsc_cgc_usb passes on USB loop rounds and fails on a veneer error" {
    const pair = probes.find("tz_nsc_cgc_usb.elf").?;
    try std.testing.expectEqual(@as(u32, 50), pair.min);
    try std.testing.expectEqual(probes.Judgement.pass, probes.judge(pair, looping));
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(pair, not_enumerated));
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(pair, veneer_error));
    try std.testing.expectEqual(@as(?probes.Probe, null), probes.find("tz_nsc_cgc_usb_ns.elf"));
}
