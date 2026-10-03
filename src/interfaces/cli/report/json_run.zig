//! The `--report json` document: the run and cores sections (RA8EMU-347),
//! then protection (report/json_protect.zig, RA8EMU-349) and memory
//! (report/json_mem.zig, RA8EMU-350), then clocks (report/json_clock.zig,
//! RA8EMU-355).
//!
//! One line, one object, `"schema": "ra8-report/1"` first. Every key in a
//! section is always present, quiet or not, so an agent can index without
//! checking; lists (IPC channels, semaphores, doorbells) carry only the
//! units that saw traffic, each with its index. The other report sections
//! join this document under RA8EMU-198's later subtasks.
const Board = @import("../../../board/board.zig").Board;
const bus_fault = @import("../../../periph/bus_fault.zig");
const cpu_ctrl = @import("../../../periph/cpu_ctrl.zig");
const ipc = @import("../../../periph/ipc/ipc.zig");
const sync = @import("../../../periph/ipc/ipc_sync.zig");
const json = @import("json.zig");
const json_protect = @import("json_protect.zig");
const json_mem = @import("json_mem.zig");
const json_clock = @import("json_clock.zig");

pub const schema = "ra8-report/1";

/// What the run itself says: which part, which engine, how far it got.
pub const Run = struct {
    engine: []const u8,
    elapsed: u64,
    bus_errors: bus_fault.Tally = .{},
};

/// The whole document, ending in a newline.
pub fn document(out: anytype, board: *Board, of: Run) !void {
    var j = json.over(out);
    try j.open(null, '{');
    try j.field("schema", schema);
    try run(&j, board, of);
    try j.open("cores", '{');
    try cpu1(&j, &board.second_core);
    try mailbox(&j, &board.mailbox);
    try j.close('}');
    try json_protect.section(&j, board);
    try json_mem.section(&j, board);
    try json_clock.section(&j, board);
    try j.close('}');
    try out.writeByte('\n');
}

fn run(j: anytype, board: *Board, of: Run) !void {
    try j.open("run", '{');
    try j.field("part", board.part.label());
    try j.field("engine", of.engine);
    try j.field("elapsed_instructions", of.elapsed);
    try j.open("bus", '{');
    try j.field("reads", board.bus.counters.reads);
    try j.field("writes", board.bus.counters.writes);
    try j.field("unmodelled_registers", board.bus.unmodelledAddresses());
    try j.close('}');
    try j.open("bus_faults", '{');
    try j.field("raised", of.bus_errors.raised);
    try j.field("escalated", of.bus_errors.escalated);
    try j.close('}');
    try j.close('}');
}

/// CPU0's view of the second-core release handshake.
pub fn cpu1(j: anytype, unit: *const cpu_ctrl.CpuCtrl) !void {
    try j.open("cpu1", '{');
    try j.field("activated", unit.act);
    try j.field("running", unit.running());
    try j.field("mapped", unit.mapped);
    try j.field("vector_table", unit.initvtor);
    try j.field("actcsr", unit.status());
    try j.field("refused_stores", unit.refused);
    try j.close('}');
}

/// The IPC block: channels, events, and the semaphores and doorbells.
pub fn mailbox(j: anytype, unit: *const ipc.Ipc) !void {
    try j.open("ipc", '{');
    try j.field("wakes", unit.wakes);
    try j.field("undelivered", unit.undelivered);
    try j.open("channels", '[');
    for (&unit.channels, 0..) |*one, index| {
        if (one.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("sends", one.sends);
        try j.field("pushed", one.pushes);
        try j.field("taken", one.pops);
        try j.field("status", one.status());
        try j.field("lost", one.lost);
        try j.field("starved", one.starved);
        try j.field("narrow_reads", one.narrow_reads);
        try j.field("narrow_writes", one.narrow_writes);
        try j.close('}');
    }
    try j.close(']');
    try locks(j, &unit.locks);
    try j.close('}');
}

fn locks(j: anytype, unit: *const sync.Sync) !void {
    try j.open("semaphores", '[');
    for (&unit.semaphores, 0..) |*one, index| {
        if (one.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("taken", one.takes);
        try j.field("contended", one.contentions);
        try j.field("released", one.releases);
        try j.field("held", one.locked);
        try j.field("stray_releases", one.stray_releases);
        try j.field("unnamed_reads", one.unnamed_reads);
        try j.close('}');
    }
    try j.close(']');
    try j.open("doorbells", '[');
    for (&unit.doorbells, 0..) |*one, index| {
        if (one.quiet()) continue;
        try j.open(null, '{');
        try j.field("index", index);
        try j.field("sent", one.sends);
        try j.field("acknowledged", one.acks);
        try j.field("pending", one.pending);
        try j.field("coalesced", one.coalesced);
        try j.close('}');
    }
    try j.close(']');
}
