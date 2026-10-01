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
const Board = @import("../../board/board.zig").Board;
const Writer = @import("report.zig").Writer;
const report = @import("report.zig");
const report_timing = @import("report_timing.zig");
const pend_break = @import("../../core/pend_break.zig");
const idle = @import("../../core/idle.zig");
const unmask = @import("../../core/unmask.zig");
const report_steps = @import("report_steps.zig");
const clocks = @import("../../periph/clocks.zig");
const nvic = @import("../../periph/nvic.zig");
const reboot = @import("../../core/reboot.zig");
const lob = @import("../../core/lob.zig");
const csel = @import("../../core/csel.zig");
const tz = @import("../../core/tz.zig");
const elf = @import("../../core/elf.zig");
const undefined_ops = @import("../../core/undefined_ops.zig");

/// What a run accumulated, gathered so the report is asked for once.
pub const Tally = struct {
    timebase: clocks.Clocks,
    /// What the run never had to execute; src/core/idle.zig says why.
    idle: idle.Seam = .{},
    /// Pends that had to wait out PRIMASK; src/core/unmask.zig says why.
    release: unmask.Release = .{},

    pend: pend_break.Pend = .{},
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
    try report.bus(board, out);
    try report_timing.timing(out, of.timebase, of.idle, of.interrupts, of.release, of.pend);
    try report.reboots(out, of.reboot);
    try report_steps.loops(out, of.loops);
    try report_steps.selects(out, of.selects);
    try report_steps.worlds(out, of.worlds);
    try report.blocks(board, out, of.timebase);
    try undefined_ops.print(out, image, of.undefined_found);
}
