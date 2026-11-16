//! CPU1 snapshot sections: decode and validate before committing live state.
const std = @import("std");

const chip = @import("ra8_chip");
const run_file = @import("ra8_board").snapshot.run;

const file = run_file.file;
const fields = run_file.fields;
const Second = chip.core.second.core.Second;
const Pair = chip.core.second.core.zig.run.Driver;
const NvicSource = chip.core.cpu.exception.nvic_source.NvicSource;

const second_wiring = .{ "state", "guard.unit" };
const state_wiring = .{ "wiring", "dividers", "timebase", "fault" };
const clock_wiring = .{ "per_chunk", "words" };
const FaultState = struct { pc: u32, access: @FieldType(chip.core.fault.Fault, "access") };

pub fn saveSecond(pair: *const Pair, writer: *std.Io.Writer) !void {
    var counter: std.Io.Writer.Discarding = .init(&.{});
    try secondBody(pair, &counter.writer);
    try file.writeSectionHeader(writer, .second, counter.fullCount());
    try secondBody(pair, writer);
}

fn secondBody(pair: *const Pair, writer: *std.Io.Writer) !void {
    try fields.writeExcept(writer, pair.second, second_wiring);
    var state = pair.second.state;
    state.interrupts = normalized(state.interrupts);
    try fields.writeExcept(writer, state, state_wiring);
    const fault: ?FaultState = if (pair.second.state.fault) |live| .{ .pc = live.pc, .access = live.access } else null;
    try fields.write(writer, fault);
    try fields.writeExcept(writer, pair.second.state.timebase, clock_wiring);
    try fields.writeExcept(writer, pair.ns_timebase, clock_wiring);
    try fields.write(writer, pair.cycle_remainder);
    try fields.write(writer, pair.last_ran);
    try fields.write(writer, pair.turn_state);
    var pending = pair.core.pending;
    pending.model = normalized(pending.model);
    try fields.writeExcept(writer, pending, .{ "banked", "clear_due" });
}

pub const PairState = struct {
    second: Second,
    ns_timebase: @FieldType(Pair, "ns_timebase"),
    cycle_remainder: u64,
    last_ran: u64,
    turn: @FieldType(Pair, "turn_state"),
    pending: NvicSource,

    pub fn commit(self: PairState, pair: *Pair) void {
        pair.second = self.second;
        pair.ns_timebase = self.ns_timebase;
        pair.cycle_remainder = self.cycle_remainder;
        pair.last_ran = self.last_ran;
        pair.turn_state = self.turn;
        pair.core.pending = self.pending;
    }
};

pub fn readSecond(pair: *const Pair, bytes: []const u8) !PairState {
    const section = try file.Reader.find(bytes, .second) orelse return error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    var second = pair.second;
    try fields.readOver(&cursor, &second, second_wiring);
    try fields.readOver(&cursor, &second.state, state_wiring);
    const fault = try fields.read(?FaultState, &cursor);
    second.state.fault = if (fault) |saved| .{
        .pc = saved.pc,
        .access = saved.access,
        .detail = "restored CPU1 fault",
    } else null;
    try fields.readOver(&cursor, &second.state.timebase, clock_wiring);
    var ns_timebase = pair.ns_timebase;
    try fields.readOver(&cursor, &ns_timebase, clock_wiring);
    const remainder = try fields.read(u64, &cursor);
    const ran = try fields.read(u64, &cursor);
    const turn = try fields.read(@FieldType(Pair, "turn_state"), &cursor);
    if (turn.elapsed > turn.share or
        turn.slots > turn.elapsed or
        turn.hz == 0 or
        turn.hz > chip.periph.clocks.timebase.default_hz or
        remainder >= chip.periph.clocks.timebase.default_hz) return error.BadValue;
    if (!turn.open and (turn.share != 0 or turn.elapsed != 0 or turn.slots != 0)) return error.BadValue;
    var pending = pair.core.pending;
    try fields.readOver(&cursor, &pending, .{ "banked", "clear_due" });
    if (!cursor.done() or
        second.regions.selected >= second.regions.table.len or
        second.partitions.selected >= second.partitions.table.len or
        second.state.interrupts.depth > second.state.interrupts.active.len or
        pending.model.depth > pending.model.active.len) return error.BadValue;
    return .{
        .second = second,
        .ns_timebase = ns_timebase,
        .cycle_remainder = remainder,
        .last_ran = ran,
        .turn = turn,
        .pending = pending,
    };
}

pub fn normalized(model: @FieldType(NvicSource, "model")) @FieldType(NvicSource, "model") {
    var out = model;
    for (out.active[out.depth..]) |*entry| {
        entry.* = std.mem.zeroes(@TypeOf(entry.*));
    }
    return out;
}
