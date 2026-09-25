//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This first slice is the spine: read an ELF, map the board, load the image,
//! reset out of the vector table, run a bounded number of instructions, and
//! say what happened. The peripherals, the display and the TUI are ported
//! from the C tree on dev, slice by slice, and land here next.
const std = @import("std");
const elf = @import("elf.zig");
const engine = @import("engine.zig");
const memmap = @import("memmap.zig");
const periph = @import("periph.zig");
const disasm = @import("disasm.zig");
const clocks = @import("clocks.zig");
const nvic = @import("nvic.zig");

const usage =
    \\usage: ra8_emulator <firmware.elf> [--instructions N]
    \\
    \\  --instructions N   stop after N instructions (default 2000000)
    \\
;

const Options = struct {
    path: []const u8,
    instructions: usize = 2_000_000,
};

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    const options = parse(argv) catch {
        std.debug.print("{s}", .{usage});
        return 2;
    };

    const file = std.fs.cwd().openFile(options.path, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ options.path, @errorName(err) });
        return 1;
    };
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 64 * 1024 * 1024);

    const image = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ options.path, @errorName(err) });
        return 1;
    };

    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();

    var bus = periph.Bus.init(allocator);
    defer bus.deinit();
    try core.attachPeriph(&bus);

    var watch = engine.Watch{};
    try core.attachWatch(&watch);
    const written = try core.loadImage(image);

    const vector_base = image.vectorBase() orelse {
        std.debug.print("no executable segment, nothing to reset into\n", .{});
        return 1;
    };
    try core.resetFromVectorTable(vector_base);

    const stack_pointer = try core.register(.sp);
    const entry = try core.register(.pc);
    var out = std.io.getStdOut().writer();
    try out.print("loaded {d} bytes, vectors at 0x{X:0>8}, sp 0x{X:0>8}, pc 0x{X:0>8}\n", .{ written, vector_base, stack_pointer, entry });

    var timebase = clocks.Clocks{};
    var interrupts = nvic.Nvic{ .vector_base = vector_base };
    const fault = try core.run(entry, options.instructions, .{
        .watch = &watch,
        .timebase = &timebase,
        .interrupts = &interrupts,
    });
    try out.print(
        "peripheral accesses: {d} read, {d} written, {d} distinct unmodelled registers\n",
        .{ bus.counters.reads, bus.counters.writes, bus.unmodelledAddresses() },
    );
    try out.print(
        "time: {d} cycles charged, {d} SysTick periods, {d} pended\n",
        .{ timebase.cycles, timebase.ticks, timebase.pends },
    );
    try out.print(
        "interrupts: {d} taken, {d} returned, {d} held\n",
        .{ interrupts.taken, interrupts.returned, interrupts.held },
    );
    if (fault) |taken| {
        try out.print("stopped at pc 0x{X:0>8}: {s}\n", .{ taken.pc, taken.detail });
        if (taken.instruction) |text| try out.print("  instruction: {s}\n", .{text.slice()});
        if (taken.access) |access| try out.print(
            "  {s} of {d} bytes at 0x{X:0>8}\n",
            .{ @tagName(access.kind), access.size, access.address },
        );
        return 1;
    }
    try out.print("ran {d} instructions clean, pc 0x{X:0>8}\n", .{ options.instructions, try core.register(.pc) });
    return 0;
}

fn parse(argv: []const []const u8) !Options {
    if (argv.len < 2) return error.MissingImage;
    var options = Options{ .path = argv[1] };
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        if (std.mem.eql(u8, argv[index], "--instructions")) {
            index += 1;
            if (index >= argv.len) return error.MissingValue;
            options.instructions = try std.fmt.parseInt(usize, argv[index], 10);
        } else return error.UnknownFlag;
    }
    return options;
}

test "the command line takes an image and an optional instruction budget" {
    const defaults = try parse(&[_][]const u8{ "emu", "a.elf" });
    try std.testing.expectEqualStrings("a.elf", defaults.path);
    try std.testing.expectEqual(@as(usize, 2_000_000), defaults.instructions);

    const bounded = try parse(&[_][]const u8{ "emu", "a.elf", "--instructions", "64" });
    try std.testing.expectEqual(@as(usize, 64), bounded.instructions);

    try std.testing.expectError(error.MissingImage, parse(&[_][]const u8{"emu"}));
    try std.testing.expectError(error.UnknownFlag, parse(&[_][]const u8{ "emu", "a.elf", "--nope" }));
}

test {
    std.testing.refAllDecls(@This());
    _ = memmap;
    _ = elf;
    _ = engine;
    _ = periph;
    _ = disasm;
    _ = clocks;
    _ = nvic;
}
