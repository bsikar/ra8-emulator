//! Served snapshots prepare every section before a non-failing guest commit.
//! Debugger points and host attachments remain outside guest state.
const state_fields = @import("state_fields.zig");
const std = @import("std");

const Board = @import("ra8_board").board.Board;
const BoardBoundary = @import("boundary.zig").BoardBoundary;
const chip = @import("ra8_chip");

const Cpu = chip.core.cpu.cpu.Cpu;
const Store = chip.core.cpu.memory.store.Store;
const board_snap = @import("ra8_board").snapshot.board;
const run_file = @import("ra8_board").snapshot.run;

const systick = chip.snapshot.systick;
const stretch = @import("ra8_board").snapshot.stretch;

const file = run_file.file;
const fields = run_file.fields;
const Driver = @import("../step_hook.zig").Driver;
const Machine = @import("../stop_machine.zig").Machine;
const Session = @import("../api.zig").Session;

const Pair = chip.core.second.core.zig.run.Driver;
const NvicSource = chip.core.cpu.exception.nvic_source.NvicSource;
const attachment_snapshot = @import("attachments.zig");
const second_state = @import("second_state.zig");

pub const attachments = attachment_snapshot;
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
    image_hash: ?[16]u8 = null,
    images: ?*const [2]?[]u8 = null,
    hashes: ?*const [2]?[16]u8 = null,
    pending: ?*NvicSource = null,
    attachments: ?attachment_snapshot.Binding = null,

    pub fn writeTo(self: *Files, writer: *std.Io.Writer) !void {
        return self.writeParts(writer, .{});
    }

    /// The save stream with only `parts` (run_file.Parts) written.
    pub fn writeParts(self: *Files, writer: *std.Io.Writer, parts: run_file.Parts) !void {
        comptime if (!complete()) @compileError("unclassified Session snapshot field");
        try self.single();
        comptime if (!attachment_snapshot.inventory.complete()) @compileError("unclassified attachment field");
        var attachment_graph: attachment_snapshot.graph.Graph = .{};
        _ = try attachment_snapshot.capture(self.board, self.attachments, &attachment_graph);
        const count: usize = if (self.pair != null) 2 else 1;
        const stores = self.storesOf();
        const cores = self.coresOf();
        try run_file.savePairParts(writer, stores[0..count], cores[0..count], self.board, self.identity(), parts);
        try self.writeTail(writer);
        try attachment_snapshot.save(self.board, self.attachments, writer);
    }

    /// The clock, grid, second core, debug unit and runtime sections.
    pub fn writeTail(self: *Files, writer: *std.Io.Writer) !void {
        try systick.save(.{ &self.edge.timebase, &self.edge.ns_timebase }, writer);
        try stretch.save(.{ .owed = self.edge.saved.stretch.carry }, writer);
        try stretch.saveGrid(self.edge.saved, writer);
        if (self.pair) |pair| try saveSecond(pair, writer);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try self.debugBody(&counter.writer);
        try file.writeSectionHeader(writer, .debug_units, counter.fullCount());
        try self.debugBody(writer);
        try file.writeSectionHeader(writer, .session_runtime, if (self.edge.chunk != null) 9 else 1);
        try fields.write(writer, if (self.edge.chunk) |chunk| @as(?u64, chunk.mark) else @as(?u64, null));
    }

    /// Puts the whole saved run back; a reverse window of the run before it goes.
    pub fn readFrom(self: *Files, bytes: []const u8) !void {
        try self.readParts(bytes, .{});
        if (self.session) |session| {
            session.dropWindow();
            if (session.history) |history| if (!history.edits.restoring) history.edits.clear();
        }
    }

    /// Restores only `parts`; the board's attachments follow the board.
    pub fn readParts(self: *Files, bytes: []const u8, parts: run_file.Parts) !void {
        try self.single();
        try board_snap.machineOf(self.board.desc(), bytes);
        var bases = .{ self.edge.timebase, self.edge.ns_timebase };
        try systick.load(.{ &bases[0], &bases[1] }, bytes);
        _ = try file.Reader.find(bytes, .stretch) orelse return error.Missing;
        const debt = try stretch.load(bytes);
        const grid = try stretch.loadGrid(bytes);
        if (debt.owed != grid.stretch.carry or
            debt.cycle_remainder != 0 or
            debt.boundary_hz != null) return error.BadValue;
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
        var staged = try run_file.prepareParts(
            bytes,
            stores[0..count],
            cores[0..count],
            self.board,
            self.identity(),
            parts,
        );
        defer staged.deinit();
        if (grid.cut) {
            const selected = if (grid.cut_pending.bank == .secure) bases[0] else bases[1];
            if (selected.rearms == 0) return error.BadValue;
        }
        if (grid.stretch.full != 0) {
            for (0..count) |index| {
                if (grid.base[index] +| grid.lengths[index] != staged.cores[index].slots) return error.BadValue;
            }
        }
        for (units[0..count], 0..) |unit, index| {
            if (unit.count.slots > staged.cores[index].slots) return error.BadValue;
        }
        if (second) |saved| {
            if (saved.turn.open and grid.at.phase != .cpu1) return error.BadValue;
            if (saved.turn.open and saved.turn.slots != grid.lengths[1]) return error.BadValue;
            if (saved.turn.open and
                (!chip.core.scheduler.validTurnShare(grid.stretch.carry, saved.turn.share) or
                    saved.last_ran != 0)) return error.BadValue;
            if (saved.second.state.ran > 0xffffffffffffffff - @as(u64, saved.turn.slots)) return error.BadValue;
            if (saved.last_ran > std.math.maxInt(u32)) return error.BadValue;
            // Completed turns charge ran; only the current open turn still has uncharged slots.
            if (grid.stretch.full != 0 and
                saved.second.state.ran + saved.turn.slots != staged.cores[1].slots) return error.BadValue;
            // A closed turn in CPU1's phase is one not opened yet: slots there mean a turn was dropped.
            if (!saved.turn.open and grid.at.phase == .cpu1 and grid.lengths[1] != 0) return error.BadValue;
        } else if (grid.at.phase == .cpu1 or grid.lengths[1] != 0) return error.BadValue;
        var attachment_state = if (parts.board) try attachment_snapshot.prepare(
            self.board,
            self.attachments,
            bytes,
        ) else null;
        defer if (attachment_state) |*held| held.deinit();
        staged.commit(stores[0..count], cores[0..count], self.board);
        if (attachment_state) |*held| held.commit(self.board, self.attachments);
        self.edge.timebase = bases[0];
        self.edge.ns_timebase = bases[1];
        self.edge.saved = grid;
        if (self.session) |session| session.grid = &self.edge.saved;
        self.edge.cut.fired = false;
        self.edge.cut.pending = null;
        self.edge.cut.seen = .{ null, null };
        self.edge.cut.seen_slot = null;
        if (second) |saved| saved.commit(self.pair.?);
        self.commitDebug(units[0..count]);
        if (self.edge.chunk) |chunk| chunk.mark = mark orelse self.cpu.retired;
    }

    fn commitDebug(self: *Files, units: []const Units) void {
        for (units, 0..) |unit, index| {
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
    }

    /// The existing host-file callers use this binding check before opening.
    pub fn single(self: *const Files) Error!void {
        if (self.edge.second != null and self.pair == null) return Error.SecondCoreNotSaved;
        const binding = self.attachments orelse {
            if (self.board.asks.needsOwner()) return Error.UnsupportedAttachments;
            if (self.session) |session| if (session.plugs != null or
                session.faults != null) return Error.UnsupportedAttachments;
            return;
        };
        if (binding.plugs.board != self.board or
            binding.faults.board != self.board) return Error.UnsupportedAttachments;
        if (self.session) |session| {
            if (session.plugs) |hook| {
                if (hook.context != @as(*anyopaque, binding.plugs)) return Error.UnsupportedAttachments;
            }
            if (session.faults) |faults| if (faults != binding.faults) return Error.UnsupportedAttachments;
        }
    }

    fn storesOf(self: *Files) [2]*Store {
        return .{ self.store, if (self.pair) |pair| &pair.store.? else self.store };
    }

    pub fn coresOf(self: *Files) [2]*Cpu {
        return .{ self.cpu, if (self.pair) |pair| &pair.core.cpu else self.cpu };
    }

    fn machineOf(self: *Files, index: usize) ?*Machine {
        const session = self.session orelse return null;
        if (session.live.index == index) return session.live.machine;
        return if (session.live.other) |other| other.machine else null;
    }

    fn driverOf(self: *Files, index: usize) ?*Driver {
        const session = self.session orelse return null;
        const watch = if (session.live.index == index)
            session.live.watch
        else if (session.live.other) |other|
            other.watch
        else
            null;
        return if (watch) |held| held.driver else null;
    }

    fn slotOf(self: *Files, index: usize) ?Slot {
        const session = self.session orelse return null;
        if (session.live.index == index) return .{ .started = &session.live.started, .count = &session.live.clock };
        if (session.live.other) |*other| return .{ .started = &other.started, .count = &other.clock };
        return null;
    }

    pub fn identity(self: *const Files) run_file.Identity {
        var out: run_file.Identity = if (self.hashes) |cached| cached.* else @splat(null);
        if (self.images) |images| for (images.*, 0..) |held, index| {
            if (out[index] == null and held != null) out[index] = run_file.imageIdentity(held.?);
        };
        if (out[0] == null) out[0] = self.image_hash orelse if (self.image) |image| run_file.imageIdentity(
            image,
        ) else null;
        return out;
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
const CycleClock = @import("../zig/cycles.zig").Clock;

const Slot = struct { started: *bool, count: *CycleClock };
pub const unit_fields = .{ "fpb", "dwt", "itm", "dcb", "unit_pending", "monitor_pending", "halting" };

pub const complete = state_fields.complete;

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
    count: CycleClock = .{},
    started: bool = false,
    nvic: ?@FieldType(NvicSource, "model") = null,
    last_non_secure: ?u9 = null,

    fn of(machine: *const Machine) Units {
        var out: Units = .{};
        inline for (unit_fields) |name| {
            @field(out, name) = @field(machine, name);
        }
        return out;
    }

    fn commit(self: Units, machine: *Machine) void {
        inline for (unit_fields) |name| {
            @field(machine, name) = @field(self, name);
        }
        machine.hits_len = 0;
        machine.hits_overflow = false;
        machine.unit_held = 0;
        machine.monitor_extra = null;
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
        if (unit.unit_pending) |pending| {
            if (pending >= @max(unit.fpb.comps.len, unit.dwt.comps.len)) return error.BadValue;
        }
        if (unit.nvic) |model| if (model.depth > model.active.len) return error.BadValue;
    }
    if (!cursor.done()) return error.BadValue;
}

pub const saveSecond = second_state.saveSecond;
pub const readSecond = second_state.readSecond;
pub const PairState = second_state.PairState;
const normalized = second_state.normalized;
