//! The `--save-state` / `--load-state` hook on a plain Zig run. The run file,
//! typed attachment owner, scheduler grid, both SysTick bases and clock debt
//! are one prepared restore, with no guest mutation before validation.
//!
//! `--snapshot-at` writes the same file at the first closed stretch at or
//! past its time, owing nothing, and the run goes on (RA8EMU-769).
//!
const std = @import("std");
const backing = @import("ra8_board").external.backing;
const boot = @import("ra8_chip").core.cpu.boot;
const Cpu = @import("ra8_chip").core.cpu.cpu.Cpu;
const Store = @import("ra8_chip").core.cpu.memory.store.Store;
const run_file = @import("ra8_board").snapshot.run;
const systick = @import("ra8_chip").snapshot.systick;
const stretch = @import("ra8_board").snapshot.stretch;
const scheduler = @import("ra8_chip").core.scheduler;
const attachments = @import("../board/attachments.zig");
const state = @import("../board/state.zig");
const Clock = @import("../run/clock.zig").Clock;

/// The largest file a load reads.
const max_bytes = 1 << 30;

pub const Error = error{ SecondCoreNotSaved, MissingImageIdentity };
pub const imageIdentity = run_file.imageIdentity;

/// The hook for `clock`'s run, or null when neither flag was given.
pub fn hook(clock: *Clock) ?boot.Snapshot {
    if (!clock.state.wanted()) return null;
    return .{
        .context = clock,
        .loadFn = if (clock.state.load != null) load else null,
        .saveFn = if (clock.state.save != null) save else null,
        .dueFn = if (clock.state.at != null) due else null,
        .atFn = if (clock.state.at != null) writeAt else null,
    };
}

fn load(context: *anyopaque, core: *Cpu) anyerror!u32 {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const allocator = std.heap.page_allocator;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(clock.io, clock.state.load.?, allocator, .limited(max_bytes));
    defer allocator.free(bytes);
    var bases = .{ clock.timebase.*, clock.ns_timebase };
    try systick.load(.{ &bases[0], &bases[1] }, bytes);
    _ = try run_file.file.Reader.find(bytes, .stretch) orelse return error.Missing;
    const debt = try stretch.load(bytes);
    const grid = try stretch.loadGrid(bytes);
    if (debt.owed != grid.stretch.carry) return error.BadValue;
    if (grid.cut) {
        const selected = if (grid.cut_pending.bank == .secure) bases[0] else bases[1];
        if (selected.rearms == 0) return error.BadValue;
    }
    const pair = clock.cpu1;
    try checkMode(bytes, pair != null);
    const count: usize = if (pair != null) 2 else 1;
    const stores: [2]*Store = .{ clock.memory.store, if (pair) |second| if (second.store != null) &second.store.? else return Error.SecondCoreNotSaved else clock.memory.store };
    const cores: [2]*Cpu = .{ core, if (pair) |second| &second.core.cpu else core };
    const second = if (pair) |held| try state.readSecond(held, bytes) else null;
    var staged = try run_file.prepareAttached(bytes, stores[0..count], cores[0..count], clock.board, try identities(clock));
    defer staged.deinit();
    if (grid.stretch.full != 0) {
        for (0..count) |index| if (grid.base[index] +| grid.lengths[index] != staged.cores[index].slots) return error.BadValue;
    }
    if (second) |saved| {
        if (saved.turn.open and grid.at.phase != .cpu1) return error.BadValue;
        if (saved.turn.open and saved.turn.slots != grid.lengths[1]) return error.BadValue;
        if (saved.turn.open and (!scheduler.validTurnShare(grid.stretch.carry, saved.turn.share) or saved.last_ran != 0)) return error.BadValue;
        if (saved.second.state.ran > std.math.maxInt(u64) - @as(u64, saved.turn.slots)) return error.BadValue;
        if (grid.stretch.full != 0 and saved.second.state.ran + saved.turn.slots != staged.cores[1].slots) return error.BadValue;
        if (!saved.turn.open and grid.at.phase == .cpu1 and grid.lengths[1] != 0) return error.BadValue;
    } else if (grid.at.phase == .cpu1 or grid.lengths[1] != 0) return error.BadValue;
    const binding = clock.snapshotBinding();
    var attachment_state = try attachments.prepare(clock.board, binding, bytes);
    defer attachment_state.deinit();
    staged.commit(stores[0..count], cores[0..count], clock.board);
    attachment_state.commit(clock.board, binding);
    if (second) |saved| saved.commit(pair.?);
    clock.timebase.* = bases[0];
    clock.ns_timebase = bases[1];
    clock.saved = grid;
    clock.accounted = core.retired -| debt.owed;
    clock.wall_cycles = if (backing.fabricOf(clock.memory.store)) |fabric| fabric.wall else 0;
    clock.cycle_remainder = debt.cycle_remainder;
    if (debt.owed != 0) {
        if (debt.rate_known) {
            clock.boundary_hz = debt.boundary_hz;
            clock.resume_unscaled = debt.boundary_hz == null;
        } else clock.resume_boundary = true;
    }
    return debt.owed;
}

fn save(context: *anyopaque, core: *const Cpu, owed: u32) anyerror!void {
    const clock: *Clock = @ptrCast(@alignCast(context));
    try write(clock, core, clock.state.save.?, owed);
}

fn due(context: *anyopaque) bool {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const wanted = clock.state.at orelse return false;
    return !wanted.written and clock.board.time.base.now() >= wanted.ns;
}

fn writeAt(context: *anyopaque, core: *const Cpu) anyerror!void {
    const clock: *Clock = @ptrCast(@alignCast(context));
    const at = &clock.state.at.?;
    try write(clock, core, at.path, 0);
    at.written = true;
}

fn checkMode(bytes: []const u8, dual: bool) !void {
    const has_second = (try run_file.file.Reader.find(bytes, .second)) != null;
    const has_memory = (try run_file.file.Reader.find(bytes, .second_memory)) != null;
    if (has_second != dual or has_memory != dual) return error.BadValue;
    var reader = try run_file.file.Reader.open(bytes);
    var cpu_count: [2]usize = .{ 0, 0 };
    while (try reader.next()) |section| {
        if (section.kind != .cpu) continue;
        if (section.payload.len == 0 or section.payload[0] > 1) return error.BadValue;
        cpu_count[section.payload[0]] += 1;
    }
    if (cpu_count[0] != 1 or cpu_count[1] != @as(usize, if (dual) 1 else 0)) return error.BadValue;
}

fn write(clock: *Clock, core: *const Cpu, path: []const u8, owed: u32) !void {
    if (owed != clock.saved.stretch.carry or !clock.saved.valid()) return error.BadValue;
    const binding = clock.snapshotBinding();
    var graph: attachments.graph.Graph = .{};
    _ = try attachments.capture(clock.board, binding, &graph);
    const pair = clock.cpu1;
    const count: usize = if (pair != null) 2 else 1;
    const stores: [2]*const Store = .{ clock.memory.store, if (pair) |second| if (second.store != null) &second.store.? else return Error.SecondCoreNotSaved else clock.memory.store };
    const cores: [2]*const Cpu = .{ core, if (pair) |second| &second.core.cpu else core };
    const image_ids = try identities(clock);
    const file = try std.Io.Dir.cwd().createFile(clock.io, path, .{});
    defer file.close(clock.io);
    var staging: [4096]u8 = undefined;
    var writer = file.writer(clock.io, &staging);
    const out = &writer.interface;
    try run_file.savePairAttached(out, stores[0..count], cores[0..count], clock.board, image_ids);
    try systick.save(.{ clock.timebase, &clock.ns_timebase }, out);
    try stretch.save(.{ .owed = owed, .cycle_remainder = clock.cycle_remainder, .boundary_hz = if (owed != 0) clock.boundary_hz else null }, out);
    try stretch.saveGrid(clock.saved, out);
    if (pair) |second| try state.saveSecond(second, out);
    try attachments.save(clock.board, binding, out);
    try out.flush();
}

fn identities(clock: *const Clock) Error!run_file.Identity {
    if (clock.cpu1 != null and (clock.image_identity == null or clock.cpu1_image_identity == null)) return Error.MissingImageIdentity;
    return .{ clock.image_identity, clock.cpu1_image_identity };
}
