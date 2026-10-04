//! The order the sections of a run's report come out in.
//!
//! Every other file in src/board writes one block's account of itself.
//! This one decides the running order and nothing else, so main.zig can ask
//! for the report in a single call and the order lives somewhere a reader
//! can find it.
//!
//! The undefined block comes last on purpose. It is the one section that
//! can invalidate everything above it: a run that executed an instruction
//! the architecture does not define has computed every address, length and
//! sector number after that point out of a program counter. Printed last it
//! reads as a verdict on the report rather than as one more block's account
//! of itself.
const Board = @import("../../../board/board.zig").Board;
const Writer = @import("../report.zig").Writer;
const report = @import("../report.zig");
const report_timing = @import("timing.zig");
const pacing = @import("../../../periph/time/pacing.zig");
const pend_break = @import("../../../core/pend_break.zig");
const mask_pace = @import("../../../core/mask_pace.zig");
const pend_pace = @import("../../../core/pend_pace.zig");
const idle = @import("../../../core/idle.zig");
const unmask = @import("../../../core/unmask.zig");
const report_steps = @import("steps.zig");
const report_part = @import("part.zig");
const clocks = @import("../../../periph/clocks.zig");
const nvic = @import("../../../periph/nvic.zig");
const reboot = @import("../../../core/reboot.zig");
const lob = @import("../../../core/lob.zig");
const csel = @import("../../../core/csel.zig");
const tz = @import("../../../core/tz.zig");
const elf = @import("../../../core/elf.zig");
const undefined_ops = @import("../../../core/undefined_ops.zig");
const bus_fault = @import("../../../periph/bus_fault.zig");
const json_run = @import("json_run.zig");
const hotspots = @import("../../../debug/hotspots.zig");
const functions = @import("../../../debug/functions.zig");
const pc_hits = @import("../../../debug/pc_hits.zig");
const tally_mod = @import("../../../debug/tally.zig");
const watchpoint = @import("../../../debug/watchpoint.zig");
const taken_in = @import("../../../debug/taken_in.zig");
const cli = @import("../cli.zig");
const rtos_report = @import("../../../debug/rtos_report.zig");

/// What a run accumulated, gathered so the report is asked for once.
pub const Tally = struct {
    timebase: clocks.Clocks,
    /// What the run never had to execute; src/core/idle.zig says why.
    idle: idle.Seam = .{},
    /// Pends that had to wait out PRIMASK; src/core/unmask.zig says why.
    release: unmask.Release = .{},

    pend: pend_break.Pend = .{},
    /// Boundaries cut short to shorten a switch's wait;
    /// src/core/pend_pace.zig says why.
    pacing: pend_pace.Pace = .{},
    /// Boundaries cut short while a masked pend stayed stuck;
    /// src/core/mask_pace.zig says what the seam's forgetting costs.
    mask_pacing: mask_pace.Pace = .{},
    interrupts: nvic.Nvic,
    reboot: reboot.Reboot,
    loops: lob.Loops,
    selects: csel.Selects,
    worlds: tz.Worlds,
    undefined_found: undefined_ops.Found,
    /// BusFaults raised for refused accesses; only a `--bus-errors` run
    /// raises any, so every other run prints exactly what it did before.
    bus_errors: bus_fault.Tally = .{},
    /// Where the run spent itself, read only by `--report json`; the text
    /// report prints these from main.zig after this block.
    pcs: hotspots.Table = .{},
    fns: ?functions.Table = null,
    profile: ?functions.profile.Table = null,
    /// The site tables main.zig prints after this block, read only by
    /// `--report json` (RA8EMU-382).
    hits: pc_hits.Hits = .{},
    taken: tally_mod.Tally = .{},
    taken_in_spec: ?[]const u8 = null,
    taken_in: ?taken_in.Window = null,
    /// What the dump flags read from (RA8EMU-381), `--report json` only.
    dumps: ?json_run.json_dumps.Dumps = null,
    /// The `--cpu-load` tracers (RA8EMU-266), `--report json` only.
    load: ?json_run.json_load.Load = null,

    /// This tally with the traced cores `--cpu-load` reads, when it asked.
    pub fn loaded(self: Tally, wanted: bool, cpu0: ?rtos_report.Side, cpu1: ?rtos_report.Side) Tally {
        var with = self;
        if (wanted) with.load = .{ .cpu0 = cpu0, .cpu1 = cpu1 };
        return with;
    }
};

/// Say what the board and the image have to say, in reading order: the bus,
/// then time, then the stepped instruction counts, then the blocks, then
/// the instructions the architecture does not define.
pub fn all(out: Writer, board: *Board, image: elf.Image, of: Tally) !void {
    try report_part.print(out, board.part);
    try report.bus(board, out);
    try report_timing.timing(out, of.timebase, of.idle, of.interrupts, of.release, of.pend, of.pacing, of.mask_pacing);
    try pacing.line(out, &board.time);
    try board.time.soak.line(out);
    try report.reboots(out, of.reboot);
    try report_steps.loops(out, of.loops);
    try report_steps.selects(out, of.selects);
    try report_steps.worlds(out, of.worlds);
    try report.blocks(board, out, of.timebase);
    try busErrors(out, of.bus_errors);
    try undefined_ops.print(out, image, of.undefined_found);
}

/// `--report json` swaps this block for one JSON line (RA8EMU-347). Text
/// stays the default and goes through `all` untouched.
pub fn pick(out: Writer, board: *Board, image: elf.Image, of: Tally, as_json: bool) !void {
    if (!as_json) return all(out, board, image, of);
    try json_run.document(out, board, .{ .engine = "unicorn", .elapsed = of.timebase.elapsed, .bus_errors = of.bus_errors, .where = .{
        .image = image,
        .steps = .{ .loops = of.loops, .selects = of.selects, .worlds = of.worlds },
        .pcs = &of.pcs,
        .fns = if (of.fns) |*table| table else null,
        .profile = if (of.profile) |*table| table else null,
    }, .timing = &.{
        .timebase = of.timebase,
        .seam = of.idle,
        .interrupts = of.interrupts,
        .release = of.release,
        .pending = of.pend,
        .pacing = of.pacing,
        .masking = of.mask_pacing,
    }, .sites = &.{
        .image = image,
        .pend = of.pend.sites,
        .gave_up = of.release.gave_up,
        .hits = &of.hits,
        .taken = &of.taken,
        .taken_in_spec = of.taken_in_spec,
        .taken_in = if (of.taken_in) |*one| one else null,
    }, .dumps = if (of.dumps) |*one| one else null, .load = if (of.load) |*one| one else null });
}

/// One line for the BusFaults a run raised, and nothing when it raised none.
pub fn busErrors(out: Writer, tally: bus_fault.Tally) !void {
    if (tally.raised == 0) return;
    try out.print("bus faults: {d} raised, {d} escalated to HardFault\n", .{ tally.raised, tally.escalated });
}

/// What a `--cpu zig` run can report: the part, the bus, its own timebase
/// and the blocks, with the instructions it retired as the elapsed time. The
/// pend/idle seams and the stepped-instruction counts are fed by hooks only
/// the Unicorn run attaches, so they are left out and a line says so.
pub fn zigCore(out: Writer, board: *Board, timebase: clocks.Clocks, retired: u64) !void {
    try report_part.print(out, board.part);
    try report.bus(board, out);
    try report_timing.clock(out, timebase);
    try pacing.line(out, &board.time);
    try board.time.soak.line(out);
    try out.print("zig core: pend/idle seams and stepped-instruction counts are Unicorn-only, not reported\n", .{});
    try report.blocks(board, out, .{ .elapsed = retired });
}
