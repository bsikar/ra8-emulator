//! The cross-core part of the end-of-run report: what went through the IPC
//! mailbox, and what the other core was supposed to hear about.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;
const ipc = @import("../periph/ipc.zig");

/// One line per channel that carried anything, plus the losses. A message a
/// full FIFO dropped and a read that found nothing are both real failures of
/// the handshake, so they are reported apart from the traffic that worked.
pub fn sections(board: *Board, out: Writer) !void {
    const mailbox = &board.mailbox;
    if (mailbox.quiet()) return;
    for (&mailbox.channels, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "IPC ch{d}: {d} poke(s), {d} word(s) sent, {d} taken, STA 0x{X:0>8}\n",
            .{ index, unit.sends, unit.pushes, unit.pops, unit.status() },
        );
        if (unit.lost != 0) {
            try out.print(
                "IPC ch{d}: {d} message(s) LOST, the four stages were full\n",
                .{ index, unit.lost },
            );
        }
        if (unit.starved != 0) {
            try out.print(
                "IPC ch{d}: {d} read(s) with the FIFO empty, no message was there\n",
                .{ index, unit.starved },
            );
        }
    }
    if (mailbox.wakes != 0) {
        try out.print("IPC: {d} receive event(s) raised on this core\n", .{mailbox.wakes});
    }
    if (mailbox.undelivered != 0) {
        try out.print(
            "IPC: {d} poke(s) addressed to the secondary core, which this build does not run\n",
            .{mailbox.undelivered},
        );
    }
}
