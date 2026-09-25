//! The end-of-run narration: what the board saw, in the order a person reads
//! it. Kept apart from board.zig so the models and the words about them do
//! not share a file, and apart from main.zig so main stays wiring.
const std = @import("std");

const Board = @import("board.zig").Board;

const clocks = @import("../periph/clocks.zig");
const nvic = @import("../periph/nvic.zig");
const cac = @import("../periph/cac.zig");
const gpio = @import("../periph/gpio.zig");
const lvd = @import("../periph/lvd.zig");
const reset = @import("../periph/reset.zig");
const engine = @import("../core/engine.zig");
const lob = @import("../core/lob.zig");

pub const Writer = std.fs.File.Writer;

pub fn bus(board: *Board, out: Writer) !void {
    try out.print(
        "peripheral accesses: {d} read, {d} written, {d} distinct unmodelled registers\n",
        .{ board.bus.counters.reads, board.bus.counters.writes, board.bus.unmodelledAddresses() },
    );
    if (board.modules.clean()) {
        try out.print("module stop: every peripheral the firmware touched was clocked\n", .{});
        return;
    }
    // Loud on purpose: on silicon these reads give zero and these writes
    // vanish, which is the bug the emulator used to hide.
    try out.print(
        "module stop: DROPPED {d} read(s) and {d} write(s) to stopped peripheral(s), last {s}, firmware forgot to cancel module stop\n",
        .{ board.modules.gated_reads, board.modules.gated_writes, board.modules.last_gated },
    );
}

/// One line per block that was actually used, so a run only reports the
/// peripherals the firmware touched.
pub fn blocks(board: *Board, out: Writer) !void {
    if (!board.checksum.quiet()) {
        try out.print(
            "CRC: GPS={d}, CRCDOR 0x{X:0>8}, {d} byte(s) folded\n",
            .{ @intFromEnum(board.checksum.gps()), board.checksum.dor, board.checksum.bytes },
        );
    }
    if (!board.dataops.quiet()) {
        try out.print(
            "DOC: OMS={d}, DODSR0 0x{X:0>8}, DOPCF={d}, {d} operation(s)\n",
            .{ @intFromEnum(board.dataops.mode()), board.dataops.dodsr0, @intFromBool(board.dataops.flag), board.dataops.ops },
        );
    }
    if (!board.accuracy.quiet()) try accuracy(board, out);
    try watchdog(board, out);
    try causes(board, out);
    try monitors(board, out);
    try events(board, out);
    try serial(board, out);
    try protection(board, out);
    try leds(board, out);
}

fn accuracy(board: *Board, out: Writer) !void {
    try out.print(
        "CAC: {d} measurement(s), count {d}, window [{d},{d}], FERRF={d}\n",
        .{
            board.accuracy.measurements,
            board.accuracy.cacntbr,
            board.accuracy.callvr,
            board.accuracy.caulvr,
            @intFromBool(board.accuracy.flagSet(cac.status.ferrf)),
        },
    );
}

/// The refused refresh is the loud case: on silicon an early reload is a
/// refresh error that resets the part, and the C tree accepts it silently.
fn watchdog(board: *Board, out: Writer) !void {
    const unit = &board.watchdog;
    if (unit.quiet()) return;
    if (unit.early != 0) {
        try out.print("WDT0: refreshes={d} REFUSED={d} (refresh outside the RPSS/RPES window, REFEF latched)\n", .{ unit.refreshes, unit.early });
    } else {
        try out.print("WDT0: refreshes={d}, counter {d}/{d}, underflows={d}\n", .{ unit.refreshes, unit.counter, unit.reload(), unit.underflows });
    }
    if (unit.bad_acks == 0) return;
    try out.print("WDT0: {d} ack(s) wrote a one at a flag and cleared nothing (WDTSR is write-zero-to-clear)\n", .{unit.bad_acks});
}

/// Why the part booted, and whether anything asked it to boot again. A
/// requested reset is reported loudly: silicon reboots there, and this tree
/// latches the cause and keeps running instead.
fn causes(board: *Board, out: Writer) !void {
    const unit = &board.causes;
    if (unit.quiet()) return;
    try out.print("RESET: RSTSR0=0x{X:0>2} RSTSR1=0x{X:0>8} (", .{ unit.rstsr0, unit.rstsr1 });
    if (unit.rstsr0 & reset.cause.porf != 0) try out.print("POR ", .{});
    if (unit.latched(reset.cause.swrf)) try out.print("SW ", .{});
    if (unit.latched(reset.cause.wdtrf)) try out.print("WDT ", .{});
    if (unit.latched(reset.cause.iwdtrf)) try out.print("IWDT ", .{});
    try out.print(")\n", .{});
    if (unit.requests != 0) {
        try out.print(
            "RESET: {d} RESET(S) REQUESTED (silicon reboots here; the cause is latched and the run carries on)\n",
            .{unit.requests},
        );
    }
    if (unit.bad_acks == 0) return;
    try out.print(
        "RESET: {d} ack(s) wrote a one at a cause flag and cleared nothing (RSTSRn is write-zero-to-clear)\n",
        .{unit.bad_acks},
    );
}

/// One line per voltage monitor the firmware programmed. A monitor whose
/// threshold sits over the rail is reported as below, which is the reading
/// the C tree cannot give: there every PVDmSR read says the rail is fine.
fn monitors(board: *Board, out: Writer) !void {
    if (board.monitors.quiet()) return;
    for (&board.monitors.channels, lvd.names) |*channel, label| {
        if (channel.quiet()) continue;
        try out.print("{s}: {s}", .{ label, monitorState(channel) });
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
    if (board.monitors.dropped != 0) {
        try out.print(
            "SYSC-PVDLR: DROPPED {d} write(s) to PVD4/PVD5 with LOCK set (write 0 to PVDLR once to release it)\n",
            .{board.monitors.dropped},
        );
    }
}

/// What the comparator is saying right now, in the words the report uses.
fn monitorState(channel: *const lvd.Channel) []const u8 {
    if (!channel.live) return "monitor off";
    return if (channel.above) "VCC above Vdet" else "VCC BELOW Vdet";
}

/// The event links, but only once something raised an event. A re-pend is
/// reported loudly: it means a handler returned with IELSR.IR still set,
/// which on silicon re-enters that handler forever.
fn events(board: *Board, out: Writer) !void {
    if (board.events.quiet()) return;
    try out.print(
        "ICU: {d} event(s) raised, {d} line(s) pended, {d} unrouted",
        .{ board.events.raised, board.events.pends, board.events.unlinked },
    );
    if (board.events.repends != 0) {
        try out.print(", {d} RE-PENDED with IELSR.IR still latched", .{board.events.repends});
    }
    try out.print("\n", .{});
}

/// One line per SCI channel that moved bytes, plus the last console line the
/// firmware printed. A TDR write made with CCR0.TE clear never leaves the
/// transmitter on silicon, so those are reported apart from the bytes that
/// did go out.
fn serial(board: *Board, out: Writer) !void {
    if (board.serial.quiet()) return;
    for (&board.serial.channels, 0..) |*channel, index| {
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
    if (board.serial.line.lines != 0) {
        try out.print("SCI console: {d} line(s), last \"{s}\"\n", .{ board.serial.line.lines, board.serial.line.slice() });
    }
}

/// PRCR and the domain it protects. Both stay quiet when the firmware never
/// touched them, and both go loud when a write was dropped: on silicon those
/// writes vanish with no fault and no flag, which is the failure that is
/// impossible to spot from the firmware side.
fn protection(board: *Board, out: Writer) !void {
    if (!board.protection.quiet()) {
        if (board.protection.bad_key != 0) {
            try out.print(
                "SYSC-PRCR: unlocks={d} REJECTED={d} (a PRCR write without the 0xA5 key unlocks nothing)\n",
                .{ board.protection.unlocks, board.protection.bad_key },
            );
        } else {
            try out.print("SYSC-PRCR: unlocks={d}, groups 0x{X:0>4}\n", .{ board.protection.unlocks, board.protection.groups });
        }
    }
    if (board.backup.quiet()) return;
    switch (board.backup.lastDrop()) {
        .locked => try out.print(
            "VBATT-BKUP: VBTBKRn writes={d} DROPPED={d} (PRCR.PRC1 locked: unlock with 0xA502)\n",
            .{ board.backup.writes, board.backup.dropped_locked },
        ),
        .disabled => try out.print(
            "VBATT-BKUP: VBTBKRn writes={d} DROPPED={d} (VBTBER.VBAE is 0)\n",
            .{ board.backup.writes, board.backup.dropped_disabled },
        ),
        .none => try out.print("VBATT-BKUP: VBTBKRn writes={d} (domain retained)\n", .{board.backup.writes}),
    }
}

fn leds(board: *Board, out: Writer) !void {
    if (board.pins.quiet()) {
        try out.print("GPIO LEDs: none driven\n", .{});
        return;
    }
    try out.print("GPIO LEDs:", .{});
    for (gpio.leds, 0..) |led, i| {
        try out.print(" [{s} {s} x{d}]", .{
            led.name,
            if (board.pins.ledLevel(i) == 1) "ON" else "OFF",
            board.pins.ledEdges(i),
        });
    }
    try out.print("\n", .{});
}

pub fn timing(out: Writer, timebase: clocks.Clocks, interrupts: nvic.Nvic) !void {
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
pub fn loops(out: Writer, stepped: lob.Loops) !void {
    if (stepped.quiet()) return;
    try out.print(
        "low-overhead loops: {d} stepped by hand, the CPU model cannot decode Armv8.1-M\n",
        .{stepped.stepped},
    );
}

pub fn fault(out: Writer, taken: engine.Fault) !void {
    try out.print("stopped at pc 0x{X:0>8}: {s}\n", .{ taken.pc, taken.detail });
    if (taken.instruction) |text| try out.print("  instruction: {s}\n", .{text.slice()});
    if (taken.access) |access| try out.print(
        "  {s} of {d} bytes at 0x{X:0>8}\n",
        .{ @tagName(access.kind), access.size, access.address },
    );
}
