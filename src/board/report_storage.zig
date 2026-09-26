//! The storage part of the end-of-run report: what the firmware did to the
//! octal NOR flash and to the SD card, and the commands each engine
//! refused.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;

/// Both storage paths, in the order they were added to the board: the
/// octal NOR flash first, then the SD card.
pub fn sections(board: *Board, out: Writer) !void {
    try flash(board, out);
    try card(board, out);
}

/// One line per run that touched the flash. A program or erase that arrived
/// with the write-enable latch clear does nothing on silicon, and a
/// descriptor asking for more than slot 0 holds is a driver bug dev would
/// have run anyway, so both are reported apart from the work that landed.
fn flash(board: *Board, out: Writer) !void {
    const unit = &board.flash;
    if (unit.quiet()) return;
    try out.print(
        "XSPI flash: {d} read(s), {d} program(s), {d} erase(s), {d} sector(s) holding data\n",
        .{ unit.reads, unit.programs, unit.erases, unit.flash.live() },
    );
    if (unit.unarmed != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} program/erase(s) with the write-enable latch clear\n",
            .{unit.unarmed},
        );
    }
    if (unit.oversized != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} descriptor(s) asking for more than the 8 bytes slot 0 holds\n",
            .{unit.oversized},
        );
    }
    if (unit.out_of_part != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} command(s) running off the end of the part\n",
            .{unit.out_of_part},
        );
    }
    if (unit.faked != 0) {
        try out.print(
            "XSPI flash: REFUSED {d} store(s) to INTS, firmware cannot raise a completion itself\n",
            .{unit.faked},
        );
    }
    if (unit.lost != 0) {
        try out.print("XSPI flash: {d} program(s) LOST, no room to hold the sector\n", .{unit.lost});
    }
}

/// One line per run that talked to the SD host controller. A block command
/// from a card that was never selected, a FIFO touched with no transfer in
/// flight, and a store to a response register are all things dev let pass,
/// so each is reported apart from the blocks that actually moved.
fn card(board: *Board, out: Writer) !void {
    const host = &board.card;
    if (host.quiet()) return;
    try out.print(
        "SDHI card: {d} block read(s), {d} block write(s), {d} block(s) holding data, {d}-bit bus\n",
        .{ host.reads, host.writes, host.card.held(), host.lanes() },
    );
    if (host.out_of_state != 0) {
        try out.print(
            "SDHI card: REFUSED {d} block command(s), the card was not selected\n",
            .{host.out_of_state},
        );
    }
    if (host.while_reset != 0) {
        try out.print(
            "SDHI card: REFUSED {d} command(s) issued while SOFT_RST was asserted\n",
            .{host.while_reset},
        );
    }
    if (host.faked != 0) {
        try out.print(
            "SDHI card: REFUSED {d} store(s) to a response register\n",
            .{host.faked},
        );
    }
    if (host.starved != 0) {
        try out.print(
            "SDHI card: {d} SD_BUF0 access(es) with no transfer in flight\n",
            .{host.starved},
        );
    }
    if (host.narrow != 0) {
        try out.print(
            "SDHI card: REFUSED {d} SD_BUF0 access(es) narrower than the 32-bit port\n",
            .{host.narrow},
        );
    }
    if (host.card.past_end != 0) {
        try out.print(
            "SDHI card: REFUSED {d} block(s) addressed past the end of the card\n",
            .{host.card.past_end},
        );
    }
}
