//! example_table runs every ELF in a directory through the emulator and prints
//! one row per image (RA8EMU-66): the verdict, how the run ended, the last SCI
//! console line, the LEDs left on and the unmodelled register count.
//!
//!   zig build examples -- EMULATOR DIR [INSTRUCTIONS]
//!
//! An image passes when its console's last line says OK or PASS. It fails when
//! the run stopped on a fault or the console says FAIL. Anything else, LED-only
//! demos included, is unknown until a reader checks it against its README.
//! A few images need more than one budget fits; example_budgets.zig lists
//! them and the floor each runs at.
const std = @import("std");
pub const budgets = @import("example_budgets.zig");

pub const Verdict = enum { pass, fail, unknown };

pub const Row = struct {
    pub const max_leds = 8;

    console: ?[]const u8 = null,
    leds_on: [max_leds][]const u8 = undefined,
    led_count: usize = 0,
    unmodelled: ?u32 = null,
    stopped: ?[]const u8 = null,

    pub fn leds(row: *const Row) []const []const u8 {
        return row.leds_on[0..row.led_count];
    }

    pub fn verdict(row: Row) Verdict {
        if (row.stopped != null) return .fail;
        const line = row.console orelse return .unknown;
        if (std.mem.indexOf(u8, line, "FAIL") != null) return .fail;
        if (std.mem.indexOf(u8, line, "OK") != null) return .pass;
        if (std.mem.indexOf(u8, line, "PASS") != null) return .pass;
        return .unknown;
    }
};

/// Reads one emulator report. Lines it does not know are ignored, so the report
/// can grow without breaking the table.
pub fn parse(report: []const u8) Row {
    var row: Row = .{};
    var lines = std.mem.splitScalar(u8, report, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "SCI console: ")) {
            row.console = quoted(line);
        } else if (std.mem.startsWith(u8, line, "GPIO LEDs: ")) {
            readLeds(&row, line);
        } else if (std.mem.startsWith(u8, line, "peripheral accesses: ")) {
            row.unmodelled = unmodelled(line);
        } else if (std.mem.startsWith(u8, line, "stopped at ")) {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse line.len;
            row.stopped = line["stopped at ".len..colon];
        }
    }
    return row;
}

fn quoted(line: []const u8) ?[]const u8 {
    const open = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, line, '"') orelse return null;
    if (close <= open) return null;
    return line[open + 1 .. close];
}

fn readLeds(row: *Row, line: []const u8) void {
    var rest = line;
    while (std.mem.indexOfScalar(u8, rest, '[')) |open| {
        const close = std.mem.indexOfScalarPos(u8, rest, open, ']') orelse return;
        const led = rest[open + 1 .. close];
        rest = rest[close + 1 ..];
        if (std.mem.indexOf(u8, led, " ON ") == null) continue;
        if (row.led_count == Row.max_leds) return;
        const end = std.mem.indexOfScalar(u8, led, ' ') orelse led.len;
        row.leds_on[row.led_count] = led[0..end];
        row.led_count += 1;
    }
}

fn unmodelled(line: []const u8) ?u32 {
    const tail = " distinct unmodelled registers";
    const end = std.mem.indexOf(u8, line, tail) orelse return null;
    const start = (std.mem.lastIndexOfScalar(u8, line[0..end], ' ') orelse return null) + 1;
    return std.fmt.parseInt(u32, line[start..end], 10) catch null;
}

pub fn writeHeader(writer: anytype) !void {
    try writer.writeAll("| image | verdict | end | console | LEDs on | unmodelled |\n");
    try writer.writeAll("|---|---|---|---|---|---:|\n");
}

pub fn writeRow(writer: anytype, image: []const u8, row: Row) !void {
    try writer.print("| {s} | {s} | ", .{ image, @tagName(row.verdict()) });
    if (row.stopped) |where| try writer.print("stopped at {s}", .{where}) else try writer.writeAll("budget");
    try writer.print(" | {s} | ", .{row.console orelse "-"});
    if (row.led_count == 0) try writer.writeAll("-");
    for (row.leds(), 0..) |led, index| {
        if (index > 0) try writer.writeAll(" ");
        try writer.writeAll(led);
    }
    if (row.unmodelled) |count| try writer.print(" | {d} |\n", .{count}) else try writer.writeAll(" | - |\n");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    if (args.len < 3) {
        std.debug.print("usage: example_table EMULATOR DIR [INSTRUCTIONS]\n", .{});
        std.process.exit(2);
    }
    const budget: ?[]const u8 = if (args.len > 3) args[3] else null;
    const images = try listImages(allocator, args[2]);

    const out = std.io.getStdOut().writer();
    try writeHeader(out);
    for (images) |image| {
        const path = try std.fs.path.join(allocator, &.{ args[2], image });
        const report = try runImage(allocator, args[1], path, budgets.pick(image, budget));
        try writeRow(out, image, parse(report));
    }
}

fn listImages(allocator: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var names = std.ArrayList([]const u8).init(allocator);
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".elf")) continue;
        try names.append(try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn runImage(allocator: std.mem.Allocator, emulator: []const u8, path: []const u8, budget: ?[]const u8) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.appendSlice(&.{ emulator, path });
    if (budget) |count| try argv.appendSlice(&.{ "--instructions", count });
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    return std.mem.concat(allocator, u8, &.{ result.stdout, "\n", result.stderr });
}
