//! ra8_emulator: the RA8D2 board emulator (#14, the Zig rewrite).
//!
//! This file is wiring and nothing else: read an ELF, build the board, reset
//! out of the vector table, run a bounded number of instructions, and say
//! what happened. The machine lives in src/core, every block that answers on
//! the peripheral bus lives in src/periph, and both are reached through the
//! "ra8" module.
const std = @import("std");
const ra8 = @import("ra8");

const cli = ra8.core.cli;
const elf = ra8.core.elf;
const engine = ra8.core.engine;
const lob = ra8.core.lob;
const periph = ra8.periph.registry;
const cac = ra8.periph.cac;
const clocks = ra8.periph.clocks;
const nvic = ra8.periph.nvic;
const mstp = ra8.periph.mstp;
const gpio = ra8.periph.gpio;
const crc = ra8.periph.crc;
const doc = ra8.periph.doc;
const prcr = ra8.periph.prcr;
const bkup = ra8.periph.bkup;

const Writer = std.fs.File.Writer;

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const argv = try std.process.argsAlloc(allocator);
    const options = cli.parse(argv) catch {
        std.debug.print("{s}", .{cli.usage});
        return 2;
    };

    const bytes = readImage(allocator, options.path) catch return 1;
    const image = elf.Image.init(bytes) catch |err| {
        std.debug.print("{s} is not a loadable image: {s}\n", .{ options.path, @errorName(err) });
        return 1;
    };

    var core = try engine.Engine.open();
    defer core.close();
    try core.mapBoardRam();

    var board = Board.init(allocator);
    defer board.deinit();
    try board.attach(&core);

    var watch = engine.Watch{};
    try core.attachWatch(&watch);
    var loops = lob.Loops{};
    try core.attachLoops(&loops);
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

    try board.reportBus(out);
    try reportTiming(out, timebase, interrupts);
    try reportLoops(out, loops);
    try board.reportBlocks(out);
    if (fault) |taken| {
        try reportFault(out, taken);
        return 1;
    }
    try out.print("ran {d} instructions clean, pc 0x{X:0>8}\n", .{ options.instructions, try core.register(.pc) });
    return 0;
}

/// The file behind `path`, or a printed complaint and the error that caused
/// it. The bytes outlive the file and are owned by the caller's arena.
fn readImage(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 64 * 1024 * 1024);
}

/// The peripheral side of the board: the bus and every block that answers on
/// it, held together so main() stays wiring.
const Board = struct {
    bus: periph.Bus,
    modules: mstp.Mstp = .{},
    pins: gpio.Gpio,
    checksum: crc.Crc,
    dataops: doc.Doc,
    accuracy: cac.Cac,
    protection: prcr.Prcr,
    backup: bkup.Bkup,

    fn init(allocator: std.mem.Allocator) Board {
        return .{
            .bus = periph.Bus.init(allocator),
            .pins = gpio.Gpio.init(),
            .checksum = crc.Crc.init(),
            .dataops = doc.Doc.init(),
            .accuracy = cac.Cac.init(),
            .protection = prcr.Prcr.init(),
            // Patched in attach(): the backup file has to point at this
            // board's own protection model, not a copy of it.
            .backup = undefined,
        };
    }

    fn deinit(self: *Board) void {
        self.bus.deinit();
    }

    /// Order matters. The module-stop shadow goes on first and then becomes
    /// the gate the rest of the bus is filtered through; PORT follows it
    /// because PORT has no module-stop bit on this part and has to answer
    /// regardless of MSTPCRx.
    fn attach(self: *Board, core: *engine.Engine) !void {
        try self.bus.add(self.modules.block());
        self.bus.gate = self.modules.gate();
        try self.bus.add(self.pins.block());
        try self.bus.add(self.checksum.block());
        try self.bus.add(self.dataops.block());
        try self.bus.add(self.accuracy.block());
        try self.bus.add(self.protection.block());
        self.backup = bkup.Bkup.init(&self.protection);
        try self.bus.add(self.backup.block());
        try core.attachPeriph(&self.bus);
    }

    fn reportBus(self: *Board, out: Writer) !void {
        try out.print(
            "peripheral accesses: {d} read, {d} written, {d} distinct unmodelled registers\n",
            .{ self.bus.counters.reads, self.bus.counters.writes, self.bus.unmodelledAddresses() },
        );
        if (self.modules.clean()) {
            try out.print("module stop: every peripheral the firmware touched was clocked\n", .{});
            return;
        }
        // Loud on purpose: on silicon these reads give zero and these writes
        // vanish, which is the bug the emulator used to hide.
        try out.print(
            "module stop: DROPPED {d} read(s) and {d} write(s) to stopped peripheral(s), last {s}, firmware forgot to cancel module stop\n",
            .{ self.modules.gated_reads, self.modules.gated_writes, self.modules.last_gated },
        );
    }

    /// One line per block that was actually used, so a run only reports the
    /// peripherals the firmware touched.
    fn reportBlocks(self: *Board, out: Writer) !void {
        if (!self.checksum.quiet()) {
            try out.print(
                "CRC: GPS={d}, CRCDOR 0x{X:0>8}, {d} byte(s) folded\n",
                .{ @intFromEnum(self.checksum.gps()), self.checksum.dor, self.checksum.bytes },
            );
        }
        if (!self.dataops.quiet()) {
            try out.print(
                "DOC: OMS={d}, DODSR0 0x{X:0>8}, DOPCF={d}, {d} operation(s)\n",
                .{ @intFromEnum(self.dataops.mode()), self.dataops.dodsr0, @intFromBool(self.dataops.flag), self.dataops.ops },
            );
        }
        if (!self.accuracy.quiet()) {
            try out.print(
                "CAC: {d} measurement(s), count {d}, window [{d},{d}], FERRF={d}\n",
                .{
                    self.accuracy.measurements,
                    self.accuracy.cacntbr,
                    self.accuracy.callvr,
                    self.accuracy.caulvr,
                    @intFromBool(self.accuracy.flagSet(cac.status.ferrf)),
                },
            );
        }
        try self.reportProtection(out);
        try self.reportLeds(out);
    }

    /// PRCR and the domain it protects. Both stay quiet when the firmware
    /// never touched them, and both go loud when a write was dropped: on
    /// silicon those writes vanish with no fault and no flag, which is the
    /// failure that is impossible to spot from the firmware side.
    fn reportProtection(self: *Board, out: Writer) !void {
        if (!self.protection.quiet()) {
            if (self.protection.bad_key != 0) {
                try out.print(
                    "SYSC-PRCR: unlocks={d} REJECTED={d} (a PRCR write without the 0xA5 key unlocks nothing)\n",
                    .{ self.protection.unlocks, self.protection.bad_key },
                );
            } else {
                try out.print("SYSC-PRCR: unlocks={d}, groups 0x{X:0>4}\n", .{ self.protection.unlocks, self.protection.groups });
            }
        }
        if (self.backup.quiet()) return;
        switch (self.backup.lastDrop()) {
            .locked => try out.print(
                "VBATT-BKUP: VBTBKRn writes={d} DROPPED={d} (PRCR.PRC1 locked: unlock with 0xA502)\n",
                .{ self.backup.writes, self.backup.dropped_locked },
            ),
            .disabled => try out.print(
                "VBATT-BKUP: VBTBKRn writes={d} DROPPED={d} (VBTBER.VBAE is 0)\n",
                .{ self.backup.writes, self.backup.dropped_disabled },
            ),
            .none => try out.print("VBATT-BKUP: VBTBKRn writes={d} (domain retained)\n", .{self.backup.writes}),
        }
    }

    fn reportLeds(self: *Board, out: Writer) !void {
        if (self.pins.quiet()) {
            try out.print("GPIO LEDs: none driven\n", .{});
            return;
        }
        try out.print("GPIO LEDs:", .{});
        for (gpio.leds, 0..) |led, i| {
            try out.print(" [{s} {s} x{d}]", .{
                led.name,
                if (self.pins.ledLevel(i) == 1) "ON" else "OFF",
                self.pins.ledEdges(i),
            });
        }
        try out.print("\n", .{});
    }
};

fn reportTiming(out: Writer, timebase: clocks.Clocks, interrupts: nvic.Nvic) !void {
    try out.print(
        "time: {d} cycles charged, {d} SysTick periods, {d} pended\n",
        .{ timebase.cycles, timebase.ticks, timebase.pends },
    );
    try out.print(
        "interrupts: {d} taken, {d} returned, {d} held\n",
        .{ interrupts.taken, interrupts.returned, interrupts.held },
    );
}

/// Only when the hook was needed: a run of Armv8.0-M code says nothing here,
/// and a run of real Cortex-M85 code says how much of it the CPU model could
/// not reach on its own.
fn reportLoops(out: Writer, loops: lob.Loops) !void {
    if (loops.quiet()) return;
    try out.print(
        "low-overhead loops: {d} stepped by hand, the CPU model cannot decode Armv8.1-M\n",
        .{loops.stepped},
    );
}

fn reportFault(out: Writer, taken: engine.Fault) !void {
    try out.print("stopped at pc 0x{X:0>8}: {s}\n", .{ taken.pc, taken.detail });
    if (taken.instruction) |text| try out.print("  instruction: {s}\n", .{text.slice()});
    if (taken.access) |access| try out.print(
        "  {s} of {d} bytes at 0x{X:0>8}\n",
        .{ @tagName(access.kind), access.size, access.address },
    );
}
