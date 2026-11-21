//! Covers src/interfaces/cli/report/part.zig: the part line a non-default
//! run prints, and that the default part prints none.
const cli_app = @import("cli_app");
const ra8 = @import("ra8");
const std = @import("std");

const catalog = ra8.chip.core.machine.catalog;
const report_part = cli_app.report.part;

test "an RA8P1 run names its part and its cited geometry" {
    var buf: [256]u8 = undefined;
    const text = try report_part.line(&buf, .ra8p1);
    try std.testing.expect(std.mem.startsWith(u8, text, "PART: RA8P1 MRAM 1024 KB @0x02000000, SRAM 1664 KB @0x22000000"));
    try std.testing.expect(std.mem.indexOf(u8, text, "CPU0 TCM 256 KB + cache 32 KB, CPU1 TCM 128 KB + cache 32 KB") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Table 1.15") != null);
}

test "the default RA8D2 run prints no part line" {
    try std.testing.expect(!report_part.shown(.ra8d2));
    try std.testing.expect(report_part.shown(.ra8p1));
}

test "dual-core HX6538 machine report names both CPU0 and CPU1 geometry" {
    var buf: [512]u8 = undefined;
    const text = try report_part.lineMachine(&buf, &catalog.hx6538);
    try std.testing.expect(std.mem.startsWith(u8, text, "PART: HX6538 QSPI 16384 KB @0x2A000000"));
    try std.testing.expect(std.mem.indexOf(u8, text, "SRAM0 1024 KB @0x24000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "CPU0 Cortex-M55, CPU1 Cortex-M55") != null);
    try std.testing.expect(report_part.shownMachine(&catalog.hx6538));
}
