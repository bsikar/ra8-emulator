//! `--count-pc` from the command line to the end-of-run report (RA8EMU-951).
//!
//! Each test spawns the emulator this build produced on the UART corpus
//! image (tests/fixtures/uart, ra8-firmware's uart_irq_echo). Its reset
//! handler gives the counts: it is entered once, and it zeroes `.bss` one
//! word a trip. The addresses and the trip count come from the image's own
//! symbols, so a rebuilt fixture that moves the handler does not move the
//! test.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const test_paths = @import("test_paths");

const pc_hits = ra8.session.pc_hits;
const symbols = ra8.session.symbols;
const Term = std.process.Child.Term;

const image_path = @import("ctl_run.zig").uart_image;
const image_bytes = @embedFile("../../fixtures/uart/uart_irq_echo.elf");

/// The first instruction of the body of the loop that zeroes `.bss`, from
/// Reset_Handler. The one number here a rebuild of the fixture can move:
/// disassemble Reset_Handler and take the branch target of the loop.
const loop_offset: u32 = 0x62;
/// Past the reset handler's loops, which end near 6,700 instructions.
const budget = "10000";

/// The two instructions counted and how often each runs.
const Counted = struct {
    /// Reset_Handler's first instruction, entered once.
    reset: u32,
    /// The `.bss` loop's body, run once a word.
    loop: u32,
    words: u64,

    fn of() !Counted {
        const image = try ra8.board.image.elf.Image.init(image_bytes);
        const reset = (symbols.addressOf(image, "Reset_Handler") orelse return error.TestExpectedSymbol) & ~@as(u32, 1);
        const start = symbols.addressOf(image, "g_ra8_ls_sbss") orelse return error.TestExpectedSymbol;
        const end = symbols.addressOf(image, "g_ra8_ls_ebss") orelse return error.TestExpectedSymbol;
        return .{ .reset = reset, .loop = reset + loop_offset, .words = (end - start) / 4 };
    }

    /// Run the image counting both, with `more` flags after those. The
    /// handler is named as the reset vector names it, Thumb bit set.
    fn run(self: Counted, more: []const []const u8) !std.process.RunResult {
        const gpa = std.testing.allocator;
        var text: [2][10]u8 = undefined;
        const reset = try std.fmt.bufPrint(&text[0], "0x{X:0>8}", .{self.reset | 1});
        const loop = try std.fmt.bufPrint(&text[1], "0x{X:0>8}", .{self.loop});
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ test_paths.emulator, image_path, "--instructions", budget });
        try argv.appendSlice(gpa, &.{ "--count-pc", reset, "--count-pc", loop });
        try argv.appendSlice(gpa, more);
        return std.process.run(gpa, std.testing.io, .{ .argv = argv.items });
    }
};

test "a run of the corpus image reports both --count-pc counts in its text report" {
    const gpa = std.testing.allocator;
    const counted = try Counted.of();
    try std.testing.expect(counted.words > 1);
    const result = try counted.run(&.{});
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    const lines = try std.fmt.allocPrint(
        gpa,
        "time: pc 0x{X:0>8} Reset_Handler+0x0 ran 1 time(s)\ntime: pc 0x{X:0>8} Reset_Handler+0x{X} ran {d} time(s)\n",
        .{ counted.reset, counted.loop, loop_offset, counted.words },
    );
    defer gpa.free(lines);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, lines) != null);
}

test "the same run under --report json carries the counts in sites.pc_hits" {
    const gpa = std.testing.allocator;
    const counted = try Counted.of();
    const result = try counted.run(&.{ "--report", "json" });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "time: pc") == null);
    const document = result.stdout[std.mem.indexOf(u8, result.stdout, "\n{") orelse return error.TestExpectedDocument ..];
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, document, .{});
    defer parsed.deinit();
    const hits = parsed.value.object.get("sites").?.object.get("pc_hits").?.object;
    try std.testing.expectEqual(@as(i64, 0), hits.get("refused").?.integer);
    const rows = hits.get("counted").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows, [_]u32{ counted.reset, counted.loop }, [_]u64{ 1, counted.words }) |row, pc, ran| {
        try std.testing.expectEqual(@as(i64, pc), row.object.get("pc").?.integer);
        try std.testing.expectEqual(@as(i64, @intCast(ran)), row.object.get("hits").?.integer);
        try std.testing.expectEqualStrings("Reset_Handler", row.object.get("symbol").?.string);
        try std.testing.expectEqual(@as(i64, pc - counted.reset), row.object.get("offset").?.integer);
    }
}

test "one address more than a run can count is refused with the limit named" {
    var argv: [2 + 2 * (pc_hits.limits.places + 1)][]const u8 = undefined;
    argv[0..2].* = .{ test_paths.emulator, image_path };
    for (0..pc_hits.limits.places + 1) |index| argv[2 + 2 * index ..][0..2].* = .{ "--count-pc", "0x02000001" };
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = &argv });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(Term{ .exited = 2 }, result.term);
    try std.testing.expectEqualStrings("", result.stdout);
    const said = std.fmt.comptimePrint("--count-pc: a run can count at most {d} addresses\n", .{pc_hits.limits.places});
    try std.testing.expectEqualStrings(said ++ cli_app.cli.usage, result.stderr);
}
