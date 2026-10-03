//! Covers tools/hil_conf.zig against the shapes the firmware's hil.conf
//! files use.
const std = @import("std");
const table = @import("example_table");
const hil_conf = table.hil_conf;

const uart =
    \\# touch_demo
    \\HIL_MODE=uart_scrape
    \\HIL_EXPECT="touch: open=OK"
    \\HIL_EXPECT_NEGATIVE="FAIL|HardFault|TIMEOUT|hw_init"
    \\HIL_TIMEOUT_S=15
    \\
;

const probe =
    \\HIL_MODE=jlink_memprobe
    \\HIL_PROBE_SYMBOL="g_threadx_blink_tick"
    \\HIL_PROBE_MIN_ADVANCE=3
    \\HIL_PROBE_SECONDS=4
    \\HIL_PROBE_FAILURE_SYMBOL=g_bad
    \\HIL_PROBE_MAX_FAILURE=0
;

test "a uart_scrape conf gives the expected text, the negatives and the timeout" {
    const conf = hil_conf.parse(uart);
    try std.testing.expectEqualStrings("uart_scrape", conf.mode.?);
    try std.testing.expectEqualStrings("touch: open=OK", conf.expect.?);
    try std.testing.expectEqualStrings("FAIL|HardFault|TIMEOUT|hw_init", conf.expect_negative.?);
    try std.testing.expectEqual(@as(?u32, 15), conf.timeout_s);
    try std.testing.expectEqual(@as(?[]const u8, null), conf.probe_symbol);
}

test "a memprobe conf gives the probe keys, quoted or not" {
    const conf = hil_conf.parse(probe);
    try std.testing.expectEqualStrings("g_threadx_blink_tick", conf.probe_symbol.?);
    try std.testing.expectEqual(@as(?u32, 3), conf.probe_min_advance);
    try std.testing.expectEqualStrings("g_bad", conf.probe_failure_symbol.?);
    try std.testing.expectEqual(@as(?u32, 0), conf.probe_max_failure);
}

test "expected and refused match the console the way the bench scrapes it" {
    const conf = hil_conf.parse(uart);
    try std.testing.expect(conf.expected("boot\ntouch: open=OK\n"));
    try std.testing.expect(!conf.expected("touch: open=ERR"));
    try std.testing.expect(conf.refused("x HardFault at 0"));
    try std.testing.expect(!conf.refused("touch: open=OK"));
}

test "comments, blanks, CRLF, unknown keys and bad numbers are ignored" {
    const conf = hil_conf.parse("# c\r\n\r\nHIL_SELF_BUILD=1\r\nHIL_TIMEOUT_S=soon\r\nnot a line\r\nHIL_MODE = x \r\n");
    try std.testing.expectEqualStrings("x", conf.mode.?);
    try std.testing.expectEqual(@as(?u32, null), conf.timeout_s);
    try std.testing.expect(!conf.refused("anything"));
    try std.testing.expect(!conf.expected("anything"));
}
