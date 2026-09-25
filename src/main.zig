//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This first slice is the spine: read an ELF, map the board, load the image,
//! reset out of the vector table, run a bounded number of instructions, and
//! say what happened. The peripherals, the display and the TUI are ported
//! from the C tree on dev, slice by slice, and land here next.
const std = @import("std");
const ra8 = @import("ra8");

const cli = ra8.core.cli;
const elf = ra8.core.elf;
const engine = ra8.core.engine;
const periph = ra8.periph.registry;
const clocks = ra8.periph.clocks;
const nvic = ra8.periph.nvic;
const mstp = ra8.periph.mstp;
const gpio = ra8.periph.gpio;
const crc = ra8.periph.crc;
const doc = ra8.periph.doc;

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    const options = cli.parse(argv) catch {
        std.debug.print("{s}", .{cli.usage});
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
    var modules = mstp.Mstp{};
    try bus.add(modules.block());
    bus.gate = modules.gate();
    // PORT is not module-stop gated on this part, so it is added after the
    // gate and answers regardless of MSTPCRx.
    var pins = gpio.Gpio.init();
    try bus.add(pins.block());
    var checksum = crc.Crc.init();
    try bus.add(checksum.block());
    var dataops = doc.Doc.init();
    try bus.add(dataops.block());
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
    if (modules.clean()) {
        try out.print("module stop: every peripheral the firmware touched was clocked\n", .{});
    } else {
        // Loud on purpose: on silicon these reads give zero and these writes
        // vanish, which is the bug the emulator used to hide.
        try out.print(
            "module stop: DROPPED {d} read(s) and {d} write(s) to stopped peripheral(s), last {s}, firmware forgot to cancel module stop\n",
            .{ modules.gated_reads, modules.gated_writes, modules.last_gated },
        );
    }
    try out.print(
        "time: {d} cycles charged, {d} SysTick periods, {d} pended\n",
        .{ timebase.cycles, timebase.ticks, timebase.pends },
    );
    try out.print(
        "interrupts: {d} taken, {d} returned, {d} held\n",
        .{ interrupts.taken, interrupts.returned, interrupts.held },
    );
    if (!checksum.quiet()) {
        try out.print(
            "CRC: GPS={d}, CRCDOR 0x{X:0>8}, {d} byte(s) folded\n",
            .{ @intFromEnum(checksum.gps()), checksum.dor, checksum.bytes },
        );
    }
    if (!dataops.quiet()) {
        try out.print(
            "DOC: OMS={d}, DODSR0 0x{X:0>8}, DOPCF={d}, {d} operation(s)\n",
            .{ @intFromEnum(dataops.mode()), dataops.dodsr0, @intFromBool(dataops.flag), dataops.ops },
        );
    }
    if (pins.quiet()) {
        try out.print("GPIO LEDs: none driven\n", .{});
    } else {
        try out.print("GPIO LEDs:", .{});
        for (gpio.leds, 0..) |led, i| {
            try out.print(" [{s} {s} x{d}]", .{
                led.name,
                if (pins.ledLevel(i) == 1) "ON" else "OFF",
                pins.ledEdges(i),
            });
        }
        try out.print("\n", .{});
    }
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
