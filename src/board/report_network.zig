//! The CAN part of the end-of-run report: the frames a controller actually
//! put on its internal loopback, and the ones it only wrote down.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// One block per controller that saw traffic. A transmit made out of
/// operation mode moves nothing on silicon, and a delivery with no receive
/// stage free is a frame the reader never sees, so both are reported apart
/// from the frames that landed.
pub fn sections(board: *Board, out: Writer) !void {
    for (&board.can.units, 0..) |*unit, index| {
        if (unit.quiet()) continue;
        try out.print(
            "CANFD{d}: {d} frame(s) transmitted, {d} received, {d} waiting in the FIFO\n",
            .{ index, unit.sent, unit.received, unit.queue.len() },
        );
        if (unit.refused != 0) {
            try out.print(
                "CANFD{d}: REFUSED {d} transmit(s) out of operation mode, the channel was never started\n",
                .{ index, unit.refused },
            );
        }
        if (unit.filtered != 0) {
            try out.print(
                "CANFD{d}: {d} frame(s) dropped by the acceptance filter\n",
                .{ index, unit.filtered },
            );
        }
        if (unit.lost != 0) {
            try out.print("CANFD{d}: {d} frame(s) LOST, no receive stage free\n", .{ index, unit.lost });
        }
        if (unit.starved != 0) {
            try out.print("CANFD{d}: {d} pop(s) of an empty receive FIFO\n", .{ index, unit.starved });
        }
        if (unit.faked != 0) {
            try out.print(
                "CANFD{d}: REFUSED {d} store(s) into a status register the controller owns\n",
                .{ index, unit.faked },
            );
        }
    }
    if (board.can.wakes != 0) {
        try out.print("CANFD0: {d} receive event(s) raised\n", .{board.can.wakes});
    }
}
