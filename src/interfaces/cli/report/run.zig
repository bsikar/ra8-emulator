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
};

/// Say what the board and the image have to say, in reading order: the bus,
/// then time, then the stepped instruction counts, then the blocks, then
/// the instructions the architecture does not define.
pub fn all(out: Writer, board: *Board, image: elf.Image, of: Tally) !void {
    try report_part.print(out, board.part);
    try report.bus(board, out);
    try report_timing.timing(out, of.timebase, of.idle, of.interrupts, of.release, of.pend, of.pacing, of.mask_pacing);
    try report.reboots(out, of.reboot);
    try report_steps.loops(out, of.loops);
    try report_steps.selects(out, of.selects);
    try report_steps.worlds(out, of.worlds);
    try report.blocks(board, out, of.timebase);
    try undefined_ops.print(out, image, of.undefined_found);
}

/// What a `--cpu zig` run can report: the part, the bus and the blocks, with
/// the instructions it retired as the elapsed time. The timebase, the
/// pend/idle seams and the stepped-instruction counts are fed by hooks only
/// the Unicorn run attaches, so they are left out and a line says so.
pub fn zigCore(out: Writer, board: *Board, retired: u64) !void {
    try report_part.print(out, board.part);
    try report.bus(board, out);
    try out.print("zig core: timebase, pend/idle seams and stepped-instruction counts are Unicorn-only, not reported\n", .{});
    try report.blocks(board, out, .{ .elapsed = retired });
}
