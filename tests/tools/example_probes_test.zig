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
    try std.testing.expectEqualStrings("g_sbns_denied", boot.failure.?);
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

test "a hil.conf probe with no failure word judges on the match counter alone" {
    const probe = probes.fromConf("threadx_blink.elf", "g_threadx_blink_tick", 3, null, null).?;
    try std.testing.expectEqual(@as(?[]const u8, null), probe.failure);
    const report = "  dump-sym      : g_threadx_blink_tick @0x22000000 = 7 (0x00000007)\n";
    try std.testing.expectEqual(probes.Judgement.pass, probes.judge(probe, report));
    const short = "  dump-sym      : g_threadx_blink_tick @0x22000000 = 2 (0x00000002)\n";
    try std.testing.expectEqual(probes.Judgement.unknown, probes.judge(probe, short));
}

test "a short count still fails a hand-written probe, and a conf probe fails on its failure word" {
    const short = "  dump-sym      : g_ok @0x22000000 = 2 (0x00000002)\n  dump-sym      : g_bad @0x22000004 = 0 (0x00000000)\n";
    const listed: probes.Probe = .{ .image = "x.elf", .symbol = "g_ok", .min = 5, .failure = "g_bad" };
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(listed, short));
    const bad = "  dump-sym      : g_ok @0x22000000 = 9 (0x00000009)\n  dump-sym      : g_bad @0x22000004 = 1 (0x00000001)\n";
    const conf = probes.fromConf("x.elf", "g_ok", 5, "g_bad", 0).?;
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(conf, bad));
}

test "a hil.conf probe keeps its failure word and ceiling, and needs a symbol" {
    const probe = probes.fromConf("x.elf", "g_ok", null, "g_bad", 2).?;
    try std.testing.expectEqual(@as(u32, 1), probe.min);
    try std.testing.expectEqualStrings("g_bad", probe.failure.?);
    try std.testing.expectEqual(@as(u32, 2), probe.max_failure);
    try std.testing.expectEqual(@as(?probes.Probe, null), probes.fromConf("x.elf", null, 3, "g_bad", null));
}

test "gpt_edge_capture_count is judged on its GPT free-run tick" {
    const probe = probes.find("gpt_edge_capture_count.elf").?;
    try std.testing.expectEqualStrings("g_gpt_ecc_tick", probe.symbol);
    try std.testing.expectEqual(@as(u32, 5), probe.min);
    try std.testing.expect(probe.failure == null);
}

const mailbox =
    \\  dump-mem      : 0x22100034 @0x22100034
    \\                  +0x0000 0x00000003 0x00000000 0x00000000 0x00000000
    \\  dump-mem      : 0x22100008 @0x22100008
    \\                  +0x0000 0x00000001 0x68000000 0x00000100 0x00000040
    \\
;

test "a probe named by address reads the first word under its dump-mem line" {
    try std.testing.expect(probes.isPlace("0x22100034"));
    try std.testing.expectEqualStrings("--dump-mem", probes.flag("0x22100034"));
    try std.testing.expectEqualStrings("--dump-sym", probes.flag("g_gpt_ecc_tick"));
    try std.testing.expectEqual(@as(?u32, 3), probes.dumped(mailbox, "0x22100034"));
    try std.testing.expectEqual(@as(?u32, 1), probes.dumped(mailbox, "0x22100008"));
    try std.testing.expectEqual(@as(?u32, null), probes.dumped(mailbox, "0x22100000"));
}

test "ereader_m33 passes on three turns and fails short of them" {
    const probe = probes.find("ereader_m33.elf").?;
    try std.testing.expectEqual(probes.Judgement.pass, probes.judge(probe, mailbox));
    const short =
        \\  dump-mem      : 0x22100034 @0x22100034
        \\                  +0x0000 0x00000001
        \\
    ;
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(probe, short));
}

test "lcd_draw_x passes on a yellow centre word and fails on any other colour" {
    const probe = probes.find("lcd_draw_x.elf").?;
    const yellow =
        \\  dump-mem      : 0x22041740 @0x22041740
        \\                  +0x0000 0xFFE0FFE0 0xFFE0FFE0 0x001FFFE0 0x001F001F
        \\
    ;
    const blue =
        \\  dump-mem      : 0x22041740 @0x22041740
        \\                  +0x0000 0x001F001F
        \\
    ;
    try std.testing.expectEqual(probes.Judgement.pass, probes.judge(probe, yellow));
    try std.testing.expectEqual(probes.Judgement.fail, probes.judge(probe, blue));
}

test "display_pal_animation is judged on its scroll offset" {
    const probe = probes.find("display_pal_animation.elf").?;
    try std.testing.expectEqualStrings("s_scroll_offset", probe.symbol);
    try std.testing.expectEqual(@as(u32, 2), probe.min);
}
