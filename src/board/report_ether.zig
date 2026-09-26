//! The Ethernet part of the end-of-run report: how far each R-Switch port
//! got through its mode machine, and what the MDIO bus was asked.
//!
//! The refused mode step is the loud case. dev reads the mode status straight
//! out of the mode command, so an image that skipped a rung comes up
//! operational in the emulator and hangs against the real state machine. A
//! frame aimed at a PHY the board does not have, and a write to a register
//! the PHY measures itself, are the other two.
const Board = @import("board.zig").Board;
const Writer = @import("report.zig").Writer;
const eth_phy = @import("../periph/eth_phy.zig");
const net = @import("net.zig");

pub fn sections(board: *Board, out: Writer) !void {
    const cluster = &board.rswitch;
    if (cluster.quiet()) return;
    for (&cluster.ports, 0..) |*port, index| {
        if (port.quiet()) continue;
        try out.print(
            "ETHA{d}: mode {s}, {d} command(s), {d} change(s)",
            .{ index, @tagName(port.mode.mode), port.mode.commands, port.mode.changes },
        );
        try refusedSteps(&port.mode, out);
        try out.print("\n", .{});
        try mdio(index, &port.phy, out);
    }
    try gateway(cluster, out);
}

fn refusedSteps(machine: anytype, out: Writer) !void {
    if (machine.refused == 0) return;
    try out.print(
        ", {d} MODE STEP(S) REFUSED (last asked for {s})",
        .{ machine.refused, @tagName(machine.last_refused.?) },
    );
}

fn mdio(index: usize, part: *const eth_phy.Phy, out: Writer) !void {
    if (part.quiet()) return;
    try out.print(
        "RMAC{d} MDIO: {d} read(s), {d} write(s), {d} PHY reset(s)",
        .{ index, part.reads, part.writes, part.resets },
    );
    if (part.no_phy != 0) try out.print(
        ", {d} FRAME(S) ADDRESSED TO A PHY THIS BOARD DOES NOT HAVE",
        .{part.no_phy},
    );
    if (part.read_only != 0) try out.print(
        ", {d} WRITE(S) TO A REGISTER THE PHY MEASURES REFUSED",
        .{part.read_only},
    );
    if (part.unsupported != 0) try out.print(
        ", {d} CLAUSE-45 FRAME(S) REFUSED",
        .{part.unsupported},
    );
    if (part.bad_op != 0) try out.print(
        ", {d} FRAME(S) WITH NO CLAUSE-22 OPERATION REFUSED",
        .{part.bad_op},
    );
    try out.print("\n", .{});
}

fn gateway(cluster: *const net.Rswitch, out: Writer) !void {
    const agent = &cluster.gateway;
    if (agent.quiet() and cluster.pool.quiet()) return;
    try out.print(
        "GWCA: mode {s}, {d} command(s), {d} AXI init(s), {d} buffer-pool init(s)",
        .{ @tagName(agent.mode.mode), agent.mode.commands, agent.inits, cluster.pool.inits },
    );
    try refusedSteps(&agent.mode, out);
    try out.print("\n", .{});
}
