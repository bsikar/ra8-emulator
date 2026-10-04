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
const idle = @import("../../../core/idle.zig");
const report_part = @import("part.zig");
const clocks = @import("../../../periph/clocks.zig");
const bus_fault = @import("../../../periph/bus_fault.zig");

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
