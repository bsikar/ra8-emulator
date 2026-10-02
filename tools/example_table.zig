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
//! them and the floor each runs at. A few need hardware the default board
//! does not fit; example_options.zig lists the flags that fit it.
//!
//! A dual-core example is two ELFs side by side, foo.elf for CPU0 and
//! foo_cpu1.elf for CPU1 (RA8EMU-37). The pair runs as one row, foo.elf with
//! --cpu1 foo_cpu1.elf, and the CPU1 half never gets a row of its own: run
//! alone it boots from a vector table CPU0 was supposed to release.
const std = @import("std");
pub const budgets = @import("example_budgets.zig");
pub const probes = @import("example_probes.zig");
pub const options = @import("example_options.zig");

pub const Verdict = enum { pass, fail, unknown };

pub const Row = struct {
    pub const max_leds = 8;

    console: ?[]const u8 = null,
    leds_on: [max_leds][]const u8 = undefined,
    led_count: usize = 0,
    unmodelled: ?u32 = null,
    stopped: ?[]const u8 = null,
    /// The memory-probe verdict for an image example_probes.zig lists.
    probe: ?probes.Judgement = null,

    pub fn leds(row: *const Row) []const []const u8 {
        return row.leds_on[0..row.led_count];
    }

    pub fn verdict(row: Row) Verdict {
        if (row.stopped != null) return .fail;
        if (row.probe) |judged| return switch (judged) {
            .pass => .pass,
            .fail => .fail,
            .unknown => .unknown,
        };
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
        if (try isSecondHalf(allocator, image, images)) continue;
        const path = try std.fs.path.join(allocator, &.{ args[2], image });
        const second = try secondPath(allocator, args[2], image, images);
        const probe = probes.find(image);
        const report = try runImage(allocator, args[1], path, second, probe, budgets.pick(image, budget));
        var row = parse(report);
        if (probe) |wanted| row.probe = probes.judge(wanted, report);
        try writeRow(out, image, row);
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

const elf = ".elf";
const cpu1_suffix = "_cpu1.elf";

/// foo.elf's CPU1 half, foo_cpu1.elf. Caller owns the name.
pub fn cpu1Name(allocator: std.mem.Allocator, image: []const u8) ![]const u8 {
    const stem = image[0 .. image.len - elf.len];
    return std.mem.concat(allocator, u8, &.{ stem, cpu1_suffix });
}

/// True for foo_cpu1.elf when foo.elf sits beside it: that image is the
/// second half of a pair, not an example of its own.
pub fn isSecondHalf(allocator: std.mem.Allocator, image: []const u8, names: []const []const u8) !bool {
    if (!std.mem.endsWith(u8, image, cpu1_suffix)) return false;
    const partner = try std.mem.concat(allocator, u8, &.{ image[0 .. image.len - cpu1_suffix.len], elf });
    defer allocator.free(partner);
    return contains(names, partner);
}

/// The CPU1 half of `image` in the directory, when the directory has one.
/// A CPU0 image whose own stem ends in _cpu1 (threadx_cpu1.elf) still pairs:
/// main() drops true second halves with isSecondHalf before asking.
pub fn pairedWith(allocator: std.mem.Allocator, image: []const u8, names: []const []const u8) !?[]const u8 {
    const name = try cpu1Name(allocator, image);
    if (contains(names, name)) return name;
    allocator.free(name);
    return null;
}

fn contains(names: []const []const u8, wanted: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, wanted)) return true;
    }
    return false;
}

fn secondPath(allocator: std.mem.Allocator, dir: []const u8, image: []const u8, names: []const []const u8) !?[]const u8 {
    const name = try pairedWith(allocator, image, names) orelse return null;
    return try std.fs.path.join(allocator, &.{ dir, name });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn runImage(allocator: std.mem.Allocator, emulator: []const u8, path: []const u8, second: ?[]const u8, probe: ?probes.Probe, budget: ?[]const u8) ![]const u8 {
    var argv = std.ArrayList([]const u8).init(allocator);
    try argv.appendSlice(&.{ emulator, path });
    try argv.appendSlice(options.flags(std.fs.path.basename(path)));
    if (second) |cpu1| try argv.appendSlice(&.{ "--cpu1", cpu1 });
    if (probe) |wanted| try argv.appendSlice(&.{ "--dump-sym", wanted.symbol, "--dump-sym", wanted.failure });
    if (budget) |count| try argv.appendSlice(&.{ "--instructions", count });
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 16 * 1024 * 1024,
    });
    return std.mem.concat(allocator, u8, &.{ result.stdout, "\n", result.stderr });
}
