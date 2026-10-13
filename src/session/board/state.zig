//! Served snapshots prepare every section before a non-failing guest commit.
//! Debugger points and host attachments remain outside guest state.
const std = @import("std");
const chip = @import("ra8_chip");
const Board = @import("ra8_board").board.Board;
const BoardBoundary = @import("boundary.zig").BoardBoundary;
const Cpu = chip.core.cpu.cpu.Cpu;
const Store = chip.core.cpu.memory.store.Store;
const run_file = @import("ra8_board").snapshot.run;
const systick = chip.snapshot.systick;
const stretch = @import("ra8_board").snapshot.stretch;
const file = run_file.file;
const fields = run_file.fields;
const Session = @import("../api.zig").Session;
const Machine = @import("../stop_machine.zig").Machine;
const Driver = @import("../step_hook.zig").Driver;
const Second = chip.core.second.core.Second;
const Pair = chip.core.second.core.zig.run.Driver;
const NvicSource = chip.core.cpu.exception.nvic_source.NvicSource;

pub const Error = error{ SecondCoreNotSaved, UnsupportedAttachments };

pub const Hook = struct {
    context: *anyopaque,
    saveFn: *const fn (*anyopaque, []const u8) anyerror!void,
    restoreFn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn save(self: Hook, path: []const u8) anyerror!void {
        return self.saveFn(self.context, path);
    }

    pub fn restore(self: Hook, path: []const u8) anyerror!void {
        return self.restoreFn(self.context, path);
    }
};

pub const Files = struct {
    store: *Store,
    cpu: *Cpu,
    board: *Board,
    edge: *BoardBoundary,
    session: ?*Session = null,
    pair: ?*Pair = null,
    image: ?[]const u8 = null,
    images: ?*const [2]?[]u8 = null,
    pending: ?*NvicSource = null,
    plugs: ?*const @import("plug.zig").Plugs = null,
    faults: ?*const @import("faults/faults.zig").Faults = null,

    pub fn writeTo(self: *Files, writer: *std.Io.Writer) !void {
        comptime if (!complete()) @compileError("unclassified Session snapshot field");
        try self.single();
        const count: usize = if (self.pair != null) 2 else 1;
        const stores = self.storesOf();
        const cores = self.coresOf();
        try run_file.savePair(writer, stores[0..count], cores[0..count], self.board, self.identity());
        try systick.save(.{ &self.edge.timebase, &self.edge.ns_timebase }, writer);
        try stretch.save(.{}, writer);
        if (self.pair) |pair| try saveSecond(pair, writer);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try self.debugBody(&counter.writer);
        try file.writeSectionHeader(writer, .debug_units, counter.fullCount());
        try self.debugBody(writer);
        try file.writeSectionHeader(writer, .session_runtime, if (self.edge.chunk != null) 9 else 1);
        try fields.write(writer, if (self.edge.chunk) |chunk| @as(?u64, chunk.mark) else @as(?u64, null));
    }

    pub fn readFrom(self: *Files, bytes: []const u8) !void {
        try self.single();
        var bases = .{ self.edge.timebase, self.edge.ns_timebase };
        try systick.load(.{ &bases[0], &bases[1] }, bytes);
        _ = try file.Reader.find(bytes, .stretch) orelse return error.Missing;
        _ = try stretch.load(bytes);
        const count: usize = if (self.pair != null) 2 else 1;
        var units: [2]Units = @splat(.{});
        const cores = self.coresOf();
        try readDebug(bytes, units[0..count], cores[0..count]);
        const runtime = try file.Reader.find(bytes, .session_runtime) orelse return error.Missing;
        var cursor: fields.Cursor = .{ .bytes = runtime.payload };
        const mark = try fields.read(?u64, &cursor);
        if (!cursor.done() or (mark != null) != (self.edge.chunk != null)) return error.BadValue;
        var second: ?PairState = null;
        if (self.pair) |pair| second = try readSecond(pair, bytes);
        const stores = self.storesOf();
        var staged = try run_file.prepare(bytes, stores[0..count], cores[0..count], self.board, self.identity());
        defer staged.deinit();
        staged.commit(stores[0..count], cores[0..count], self.board);
        self.edge.timebase = bases[0];
        self.edge.ns_timebase = bases[1];
        if (second) |saved| saved.commit(self.pair.?);
        for (units[0..count], 0..) |unit, index| {
            if (self.machineOf(index)) |machine| unit.commit(machine);
            if (self.slotOf(index)) |held| {
                held.started.* = unit.started;
                held.count.* = unit.count;
            }
            if (self.driverOf(index)) |driver| {
                driver.unit_dirty = false;
                driver.last = null;
                driver.cycles = unit.cycles;
            }
            if (index == 0) if (self.pending) |pending| {
                pending.model = unit.nvic orelse .{};
                pending.last_non_secure = unit.last_non_secure;
            };
        }
        if (self.edge.chunk) |chunk| chunk.mark = mark orelse self.cpu.retired;
    }

    /// The existing host-file callers use this binding check before opening.
    pub fn single(self: *const Files) Error!void {
        if (self.edge.second != null and self.pair == null) return Error.SecondCoreNotSaved;
        if (self.board.asks.count != 0) return Error.UnsupportedAttachments;
        if (self.session) |session| {
            if (session.plugs) |hook| {
                const plugs = self.plugs orelse return Error.UnsupportedAttachments;
                if (@intFromPtr(hook.context) != @intFromPtr(plugs)) return Error.UnsupportedAttachments;
            }
            if (session.faults) |faults| if (!faults.snapshotSafe()) return Error.UnsupportedAttachments;
        }
        if (self.plugs) |plugs| if (!plugs.snapshotSafe()) return Error.UnsupportedAttachments;
        if (self.faults) |faults| if (!faults.snapshotSafe()) return Error.UnsupportedAttachments;
    }

    fn storesOf(self: *Files) [2]*Store {
        return .{ self.store, if (self.pair) |pair| &pair.store.? else self.store };
    }

    fn coresOf(self: *Files) [2]*Cpu {
        return .{ self.cpu, if (self.pair) |pair| &pair.core.cpu else self.cpu };
    }

    fn machineOf(self: *Files, index: usize) ?*Machine {
        const session = self.session orelse return null;
        if (session.live.index == index) return session.live.machine;
        return if (session.live.other) |other| other.machine else null;
    }

    fn driverOf(self: *Files, index: usize) ?*Driver {
        const session = self.session orelse return null;
        const watch = if (session.live.index == index) session.live.watch else if (session.live.other) |other| other.watch else null;
        return if (watch) |held| held.driver else null;
    }

    fn slotOf(self: *Files, index: usize) ?Slot {
        const session = self.session orelse return null;
        if (session.live.index == index) return .{ .started = &session.live.started, .count = &session.live.clock.count };
        if (session.live.other) |*other| return .{ .started = &other.started, .count = &other.clock.count };
        return null;
    }

    fn identity(self: *const Files) run_file.Identity {
        var hashes: run_file.Identity = @splat(null);
        if (self.image) |image| hashes[0] = run_file.imageIdentity(image);
        if (self.images) |images| for (images.*, 0..) |held, index| {
            if (held) |image| hashes[index] = run_file.imageIdentity(image);
        };
        return hashes;
    }

    fn debugBody(self: *Files, writer: *std.Io.Writer) !void {
        const count: u8 = if (self.pair != null) 2 else 1;
        try fields.write(writer, count);
        for (0..count) |index| {
            var units: Units = .{};
            if (self.machineOf(index)) |machine| units = Units.of(machine);
            if (self.driverOf(index)) |driver| units.cycles = driver.cycles;
            if (self.slotOf(index)) |held| {
                units.started = held.started.*;
                units.count = held.count.*;
            }
            if (index == 0) if (self.pending) |pending| {
                units.nvic = normalized(pending.model);
                units.last_non_secure = pending.last_non_secure;
            };
            units.dwt.numcomp = if (!self.coresOf()[index].profile.v8_1m) 4 else 8;
            @memset(units.itm.text.buffer[units.itm.text.len..], 0);
            try fields.write(writer, units);
        }
    }
};

const Count = @FieldType(Driver, "cycles");
const Slot = struct { started: *bool, count: *Count };
const unit_fields = .{ "fpb", "dwt", "itm", "dcb", "unit_pending", "monitor_pending", "halting" };

/// Classifies the fields this file picks by name. Second, its State and both
/// NVIC sources are written whole except for their validated skip paths.
pub fn complete() bool {
    const transient = "Execution control; a restore leaves the core halted";
    const points = "Debugger points stay with the attached debugger";
    const derived = "Derived cache invalidated after restore";
    return fields.complete(Machine, unit_fields, .{
        .{ .name = "breaks", .reason = points },     .{ .name = "watches", .reason = points },
        .{ .name = "next_id", .reason = points },    .{ .name = "mode", .reason = transient },
        .{ .name = "resumed", .reason = transient }, .{ .name = "halt_pending", .reason = transient },
        .{ .name = "target", .reason = transient },  .{ .name = "watch_pending", .reason = transient },
    }) and fields.complete(Driver, .{"cycles"}, .{
        .{ .name = "machine", .reason = "Session wiring" }, .{ .name = "last", .reason = transient },
        .{ .name = "latch", .reason = "Session wiring" },   .{ .name = "unit_dirty", .reason = derived },
    }) and fields.complete(Pair, .{ "second", "core", "ns_timebase", "store", "cycle_remainder", "last_ran" }, .{
        .{ .name = "wiring", .reason = "Boundary wiring" },
    }) and fields.complete(@FieldType(Pair, "core"), .{ "pending", "cpu" }, .{
        .{ .name = "memory", .reason = "Guest memory wiring" },    .{ .name = "board", .reason = "Board bus wiring" },
        .{ .name = "quiet", .reason = derived },                   .{ .name = "decoded", .reason = derived },
        .{ .name = "check", .reason = "Stable MPU-model wiring" }, .{ .name = "formed", .reason = derived },
    });
}

pub const Units = struct {
    fpb: @FieldType(Machine, "fpb") = .{},
    dwt: @FieldType(Machine, "dwt") = .{},
    itm: @FieldType(Machine, "itm") = .{},
    dcb: @FieldType(Machine, "dcb") = .{},
    unit_pending: ?usize = null,
    monitor_pending: @FieldType(Machine, "monitor_pending") = null,
    halting: bool = true,
    cycles: Count = .{},
    /// The Session slot's own CYCCNT bookkeeping and whether it has run.
    count: Count = .{},
    started: bool = false,
    nvic: ?@FieldType(NvicSource, "model") = null,
    last_non_secure: ?u9 = null,

    fn of(machine: *const Machine) Units {
        var out: Units = .{};
        inline for (unit_fields) |name| @field(out, name) = @field(machine, name);
        return out;
    }

    fn commit(self: Units, machine: *Machine) void {
        inline for (unit_fields) |name| @field(machine, name) = @field(self, name);
        machine.watch_pending = null;
        machine.halt_pending = false;
        machine.resumed = false;
        machine.target = null;
        machine.mode = .halted;
    }
};

fn readDebug(bytes: []const u8, units: []Units, cores: []const *Cpu) !void {
    const section = try file.Reader.find(bytes, .debug_units) orelse return error.Missing;
    var cursor: fields.Cursor = .{ .bytes = section.payload };
    if (try fields.read(u8, &cursor) != units.len) return error.BadValue;
    for (units, cores) |*unit, core| {
        unit.* = try fields.read(Units, &cursor);
        const expected: u4 = if (!core.profile.v8_1m) 4 else 8;
        if (unit.dwt.numcomp != expected or unit.dwt.numcomp > unit.dwt.comps.len) return error.BadValue;
        if (unit.itm.text.len > unit.itm.text.buffer.len) return error.BadValue;
        if (unit.unit_pending) |pending| if (pending >= @max(unit.fpb.comps.len, unit.dwt.comps.len)) return error.BadValue;
        if (unit.nvic) |model| if (model.depth > model.active.len) return error.BadValue;
    }
    if (!cursor.done()) return error.BadValue;
}

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
    var pending = pair.core.pending;
    pending.model = normalized(pending.model);
    try fields.writeExcept(writer, pending, .{ "banked", "clear_due" });
}

pub const PairState = struct {
    second: Second,
    ns_timebase: @FieldType(Pair, "ns_timebase"),
    cycle_remainder: u64,
    last_ran: u64,
    pending: NvicSource,

    pub fn commit(self: PairState, pair: *Pair) void {
        pair.second = self.second;
        pair.ns_timebase = self.ns_timebase;
        pair.cycle_remainder = self.cycle_remainder;
        pair.last_ran = self.last_ran;
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
    second.state.fault = if (fault) |saved| .{ .pc = saved.pc, .access = saved.access, .detail = "restored CPU1 fault" } else null;
    try fields.readOver(&cursor, &second.state.timebase, clock_wiring);
    var ns_timebase = pair.ns_timebase;
    try fields.readOver(&cursor, &ns_timebase, clock_wiring);
    const remainder = try fields.read(u64, &cursor);
    const ran = try fields.read(u64, &cursor);
    var pending = pair.core.pending;
    try fields.readOver(&cursor, &pending, .{ "banked", "clear_due" });
    if (!cursor.done() or second.regions.selected >= second.regions.table.len or second.partitions.selected >= second.partitions.table.len or second.state.interrupts.depth > second.state.interrupts.active.len or pending.model.depth > pending.model.active.len) return error.BadValue;
    return .{ .second = second, .ns_timebase = ns_timebase, .cycle_remainder = remainder, .last_ran = ran, .pending = pending };
}

fn normalized(model: @FieldType(NvicSource, "model")) @FieldType(NvicSource, "model") {
    var out = model;
    for (out.active[out.depth..]) |*entry| entry.* = std.mem.zeroes(@TypeOf(entry.*));
    return out;
}
