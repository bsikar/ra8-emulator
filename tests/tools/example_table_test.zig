//! The example table reads emulator reports the way they print today.
const std = @import("std");
const table = @import("example_table");

const console_report =
    \\loaded 56980 bytes, vectors at 0x02000000, sp 0x220FFF00, pc 0x02003570
    \\peripheral accesses: 80 read, 142 written, 1 distinct unmodelled registers
    \\SCI console: 2 line(s), last "pp: profile OK"
    \\GPIO LEDs: [LED1 BLUE  P600 ON x1] [LED2 GREEN P303 OFF x0] [LED3 RED   PA07 OFF x0]
    \\
;

const fault_report =
    \\peripheral accesses: 48 read, 182 written, 0 distinct unmodelled registers
    \\GPIO LEDs: none driven
    \\stopped at pc 0x00000000: Invalid memory fetch (UC_ERR_FETCH_UNMAPPED)
    \\  fetch of 4 bytes at 0x00000000
    \\
;

test "a console OK line passes and its fields are read" {
    const row = table.parse(console_report);
    try std.testing.expectEqualStrings("pp: profile OK", row.console.?);
    try std.testing.expectEqual(@as(?u32, 1), row.unmodelled);
    try std.testing.expectEqual(@as(usize, 1), row.leds().len);
    try std.testing.expectEqualStrings("LED1", row.leds()[0]);
    try std.testing.expectEqual(table.Verdict.pass, row.verdict());
}

test "a run that stopped on a fault fails" {
    const row = table.parse(fault_report);
    try std.testing.expectEqualStrings("pc 0x00000000", row.stopped.?);
    try std.testing.expectEqual(@as(usize, 0), row.leds().len);
    try std.testing.expectEqual(@as(?u32, 0), row.unmodelled);
    try std.testing.expectEqual(table.Verdict.fail, row.verdict());
}

test "LEDs with no console line are unknown, and FAIL fails" {
    const leds = table.parse("GPIO LEDs: [LED1 BLUE  P600 ON x1] [LED2 GREEN P303 ON x1]\n");
    try std.testing.expectEqual(@as(usize, 2), leds.leds().len);
    try std.testing.expectEqual(table.Verdict.unknown, leds.verdict());
    const failed = table.parse("SCI console: 1 line(s), last \"aes: FAIL\"\n");
    try std.testing.expectEqual(table.Verdict.fail, failed.verdict());
}

test "a row prints in table order" {
    var buffer: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buffer);
    try table.writeRow(stream.writer(), "power_profiler.elf", table.parse(console_report));
    try std.testing.expectEqualStrings(
        "| power_profiler.elf | pass | budget | pp: profile OK | LED1 | 1 |\n",
        stream.getWritten(),
    );
}
