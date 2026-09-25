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
const icu = ra8.periph.icu;
const lvd = ra8.periph.lvd;
const crc = ra8.periph.crc;
const doc = ra8.periph.doc;
const prcr = ra8.periph.prcr;
const bkup = ra8.periph.bkup;
const sci = ra8.periph.sci;
const wdt = ra8.periph.wdt;

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
        .board = board.ticker(),
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
    events: icu.Icu,
    pins: gpio.Gpio,
    checksum: crc.Crc,
    dataops: doc.Doc,
    accuracy: cac.Cac,
    protection: prcr.Prcr,
    backup: bkup.Bkup,
    serial: sci.Sci,
    monitors: lvd.Lvd,
    watchdog: wdt.Wdt,

    fn init(allocator: std.mem.Allocator) Board {
        return .{
            .bus = periph.Bus.init(allocator),
            .events = icu.Icu.init(),
            .pins = gpio.Gpio.init(),
            .checksum = crc.Crc.init(),
            .dataops = doc.Doc.init(),
            .accuracy = cac.Cac.init(),
            .protection = prcr.Prcr.init(),
            // Patched in attach(): the backup file has to point at this
            // board's own protection model, not a copy of it.
            .backup = undefined,
            .serial = sci.Sci.init(),
            .monitors = lvd.Lvd.init(),
            .watchdog = wdt.Wdt.init(),
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
        try self.bus.add(self.serial.block());
        try self.bus.add(self.events.block());
        try self.bus.add(self.monitors.statusBlock());
        try self.bus.add(self.monitors.controlBlock());
        try self.bus.add(self.monitors.filterBlock());
        try self.bus.add(self.watchdog.block());
        try core.attachPeriph(&self.bus);
    }

    /// The chunk boundary, peripheral side: every block with an event due
    /// raises it into the event links, then any line still latched re-pends.
    /// The controller picks straight afterwards, so an interrupt raised here
    /// is entered in the same boundary rather than a chunk later.
    fn tick(self: *Board, core: engine.Engine) !void {
        self.watchdog.tick();
        for (self.serial.dueEvents().constSlice()) |event| {
            try self.events.raise(core, event);
        }
        try self.events.repend(core);
    }

    fn ticker(self: *Board) engine.Tick {
        return .{ .context = self, .tickFn = tickThunk };
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
        try self.reportWatchdog(out);
        try self.reportMonitors(out);
        try self.reportEvents(out);
        try self.reportSerial(out);
        try self.reportProtection(out);
        try self.reportLeds(out);
    }

    /// The refused refresh is the loud case: on silicon an early reload is a
    /// refresh error that resets the part, and the C tree accepts it silently.
    fn reportWatchdog(self: *Board, out: Writer) !void {
        const unit = &self.watchdog;
        if (unit.quiet()) return;
        const note = if (unit.reset_requested) " RESET REQUESTED (RSTIRQS set: silicon reboots here)" else "";
        if (unit.early != 0) {
            try out.print("WDT0: refreshes={d} REFUSED={d} (refresh outside the RPSS/RPES window, REFEF latched){s}\n", .{ unit.refreshes, unit.early, note });
        } else {
            try out.print("WDT0: refreshes={d}, counter {d}/{d}, underflows={d}{s}\n", .{ unit.refreshes, unit.counter, unit.reload(), unit.underflows, note });
        }
        if (unit.bad_acks == 0) return;
        try out.print("WDT0: {d} ack(s) wrote a one at a flag and cleared nothing (WDTSR is write-zero-to-clear)\n", .{unit.bad_acks});
    }

    /// One line per voltage monitor the firmware programmed. A monitor whose
    /// threshold sits over the rail is reported as below, which is the reading
    /// the C tree cannot give: there every PVDmSR read says the rail is fine.
    fn reportMonitors(self: *Board, out: Writer) !void {
        if (self.monitors.quiet()) return;
        for (&self.monitors.channels, lvd.names) |*channel, name| {
            if (channel.quiet()) continue;
            try out.print("{s}: {s}", .{ name, monitorState(channel) });
            if (channel.crossings != 0) {
                try out.print(", {d} crossing(s), DET={d}", .{ channel.crossings, @intFromBool(channel.det) });
            }
            if (channel.refused_clears != 0) {
                try out.print(", {d} DET CLEAR(S) WRITTEN AS A 1 AND REFUSED", .{channel.refused_clears});
            }
            if (channel.reserved_level != 0) {
                try out.print(", {d} RESERVED PVDLVL ENCODING(S)", .{channel.reserved_level});
            }
            try out.print("\n", .{});
        }
        if (self.monitors.dropped != 0) {
            try out.print(
                "SYSC-PVDLR: DROPPED {d} write(s) to PVD4/PVD5 with LOCK set (write 0 to PVDLR once to release it)\n",
                .{self.monitors.dropped},
            );
        }
    }

    /// The event links, but only once something raised an event. A re-pend is
    /// reported loudly: it means a handler returned with IELSR.IR still set,
    /// which on silicon re-enters that handler forever.
    fn reportEvents(self: *Board, out: Writer) !void {
        if (self.events.quiet()) return;
        try out.print(
            "ICU: {d} event(s) raised, {d} line(s) pended, {d} unrouted",
            .{ self.events.raised, self.events.pends, self.events.unlinked },
        );
        if (self.events.repends != 0) {
            try out.print(", {d} RE-PENDED with IELSR.IR still latched", .{self.events.repends});
        }
        try out.print("\n", .{});
    }

    /// One line per SCI channel that moved bytes, plus the last console line
    /// the firmware printed. A TDR write made with CCR0.TE clear never leaves
    /// the transmitter on silicon, so those are reported apart from the bytes
    /// that did go out.
    fn reportSerial(self: *Board, out: Writer) !void {
        if (self.serial.quiet()) return;
        for (&self.serial.channels, 0..) |*channel, index| {
            if (channel.quiet()) continue;
            try out.print(
                "SCI{d}: TX {d} bytes, RX {d} bytes, {d} dropped on a full queue",
                .{ index, channel.transmitted, channel.received, channel.rx.dropped },
            );
            if (channel.unsent != 0) {
                try out.print(", {d} WRITE(S) WITH TE CLEAR NEVER SENT", .{channel.unsent});
            }
            try out.print("\n", .{});
        }
        if (self.serial.line.lines != 0) {
            try out.print("SCI console: {d} line(s), last \"{s}\"\n", .{ self.serial.line.lines, self.serial.line.slice() });
        }
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

/// What the comparator is saying right now, in the words the report uses.
fn monitorState(channel: *const lvd.Channel) []const u8 {
    if (!channel.live) return "monitor off";
    return if (channel.above) "VCC above Vdet" else "VCC BELOW Vdet";
}

fn tickThunk(context: *anyopaque, core: engine.Engine) anyerror!void {
    const board: *Board = @ptrCast(@alignCast(context));
    return board.tick(core);
}

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
