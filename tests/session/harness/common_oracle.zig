//! Independent COMMON whole-state qualification oracle (QTR-002 & QTR-003).
//! Inspects all 59 Cortex registers + hidden CPU state, all 12 backing spaces,
//! TrustZone & cross-core aliases, scheduler grid, CPU1 Second private units,
//! debug units (excluding only Units.count run-bookkeeping), board peripherals,
//! and attachment/fault graphs — with zero production snapshot codec calls.
const std = @import("std");
const ra8 = @import("ra8");
pub const hash = @import("common_hash.zig");
pub const spaces = @import("common_spaces.zig");
pub const board_oracle = @import("common_board_oracle.zig");
pub const attach_oracle = @import("common_attach_oracle.zig");

pub const Digest = hash.Digest;
pub const Position = hash.Position;
pub const Stream = hash.Stream;
const Hasher = hash.Hasher;

const Harness = ra8.session.harness.Harness;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Cortex = ra8.chip.core.cpu.cortex.Cortex;
const ZigCore = ra8.session.zig.core.ZigCore;
const Machine = ra8.session.stop_machine.Machine;
const Driver = ra8.session.step_hook.Driver;
const Pair = ra8.chip.core.second.core.zig.run.Driver;
const NvicSource = ra8.chip.core.cpu.exception.nvic_source.NvicSource;
const BoardBoundary = ra8.session.board.boundary.BoardBoundary;
const Ended = ra8.session.zig.drive.Ended;

const cpu_included = .{
    "regs",                "fp",            "retired", "slots",     "sync_entries",
    "vtor",                "raised",        "active",  "exclusive", "banked",
    "entering_non_secure", "secure_faults", "event",   "booted",    "waiting",
    "profile",
};

const cpu_excluded = .{
    .{ .name = "bus", .reason = "Host bus callback vtable wiring" },
    .{ .name = "idle_cycles", .reason = "Host run-report sleep telemetry counter" },
    .{ .name = "metrics_epoch", .reason = "Host device_metrics sampling epoch" },
    .{ .name = "retire_listener", .reason = "Debugger/profiler retire callback" },
    .{ .name = "fetch_guard", .reason = "Debugger/boundary fetch guard callback" },
    .{ .name = "source", .reason = "Exception source callback vtable" },
    .{ .name = "quiet", .reason = "Derived poll shortcut pointer" },
    .{ .name = "cut", .reason = "SysTick cut latch pointer" },
    .{ .name = "until", .reason = "Host console-until stop pointer" },
    .{ .name = "decoded", .reason = "Derived instruction decode cache pointer" },
    .{ .name = "blocks", .reason = "Derived basic-block cache pointer" },
    .{ .name = "attribution", .reason = "SAU/IDAU callback vtable wiring" },
    .{ .name = "mpu", .reason = "MPU check pointer wiring" },
    .{ .name = "event_sender", .reason = "Cross-core SEV callback wiring" },
    .{ .name = "trip", .reason = "Derived calm-loop acceleration watch" },
};

const machine_included = .{ "fpb", "dwt", "itm", "dcb", "unit_pending", "monitor_pending", "halting" };
const machine_excluded = .{
    .{ .name = "breaks", .reason = "Debugger breakpoint table outside guest state" },
    .{ .name = "watches", .reason = "Debugger watchpoint table outside guest state" },
    .{ .name = "next_id", .reason = "Debugger point ID allocator" },
    .{ .name = "mode", .reason = "Transient halted/running debugger control" },
    .{ .name = "resumed", .reason = "Transient resume flag" },
    .{ .name = "halt_pending", .reason = "Transient halt request flag" },
    .{ .name = "target", .reason = "Transient single-step target" },
    .{ .name = "hits", .reason = "Transient watchpoint hit buffer" },
    .{ .name = "hits_len", .reason = "Transient watchpoint hit count" },
    .{ .name = "hits_overflow", .reason = "Transient watchpoint overflow flag" },
    .{ .name = "unit_held", .reason = "Transient FPB/DWT hold mask" },
    .{ .name = "unit_taken", .reason = "Transient FPB/DWT taken flag" },
    .{ .name = "monitor_extra", .reason = "Transient debug monitor scratch" },
};

comptime {
    if (std.meta.tags(Cortex).len != 59) {
        @compileError("Expected all 59 Cortex architectural registers");
    }
    if (!hash.classified(Cpu, cpu_included, cpu_excluded)) {
        @compileError("Unclassified Cpu field in COMMON oracle");
    }
    if (!hash.classified(Machine, machine_included, machine_excluded)) {
        @compileError("Unclassified Machine field in COMMON oracle");
    }
    if (!hash.classified(Driver, .{"cycles"}, .{
        .{ .name = "machine", .reason = "Session Machine pointer" },
        .{ .name = "last", .reason = "Transient step state" },
        .{ .name = "latch", .reason = "Session latch pointer" },
        .{ .name = "unit_dirty", .reason = "Derived unit-dirty flag" },
    })) @compileError("Unclassified Driver field in COMMON oracle");
    if (!hash.classified(Pair, .{ "second", "core", "ns_timebase", "store", "cycle_remainder", "last_ran", "turn_state" }, .{
        .{ .name = "wiring", .reason = "Boundary wiring pointers" },
    })) @compileError("Unclassified Pair field in COMMON oracle");
    if (!hash.classified(BoardBoundary, .{ "timebase", "ns_timebase", "saved", "chunk" }, .{
        .{ .name = "board", .reason = "Board pointer" },
        .{ .name = "core", .reason = "CPU0 Guest handle" },
        .{ .name = "cpu", .reason = "CPU0 pointer" },
        .{ .name = "reboot", .reason = "Reboot pointer" },
        .{ .name = "selected", .reason = "Debugger selected core view" },
        .{ .name = "second", .reason = "Second pointer" },
        .{ .name = "second_memory", .reason = "CPU1 Guest handle" },
        .{ .name = "pair", .reason = "Pair pointer" },
        .{ .name = "cut", .reason = "Transient cut wiring; consumed state is in saved.cut" },
        .{ .name = "idle_skip", .reason = "Immutable root grid option" },
    })) @compileError("Unclassified BoardBoundary field in COMMON oracle");
}

pub const Capture = struct {
    position: Position,
    cores: [2]?Digest,
    stores: [2]?Digest,
    spaces: Digest,
    aliases: spaces.AliasState,
    fabric: Digest,
    scheduler: Digest,
    second_units: ?Digest,
    debug_units: Digest,
    peripherals: Digest,
    attachments: Digest,

    pub fn first(a: Capture, b: Capture) ?[]const u8 {
        inline for (.{
            "position", "cores",       "aliases",      "stores",
            "spaces",   "scheduler",   "second_units", "debug_units",
            "fabric",   "peripherals", "attachments",
        }) |domain| {
            if (!std.meta.eql(@field(a, domain), @field(b, domain))) return domain;
        }
        return null;
    }
};

/// Hashes all 59 Cortex architectural registers via ZigCore PLUS all raw
/// architectural, FPU/MVE, security/banked, exclusive, active, and lifecycle
/// fields on `Cpu`.
pub fn core(cpu: *const Cpu) Digest {
    var h: Hasher = .{};
    const view: ZigCore = .{ .cpu = @constCast(cpu) };
    inline for (std.meta.tags(Cortex)) |reg_tag| {
        h.auto(reg_tag);
        h.int(view.register(reg_tag));
    }
    inline for (.{
        "regs",                "fp",            "retired", "slots",     "sync_entries",
        "booted",              "vtor",          "raised",  "exclusive", "banked",
        "entering_non_secure", "secure_faults", "event",   "waiting",   "profile",
    }) |name| {
        h.auto(@field(cpu, name));
    }
    const depth = @min(cpu.active.depth, cpu.active.stack.len);
    h.int(cpu.active.depth);
    for (cpu.active.stack[0..depth]) |entry| h.auto(entry);
    return h.final();
}

fn hashNvicModel(h: *Hasher, src: *const NvicSource) void {
    var model = src.model;
    const depth = @min(model.depth, model.active.len);
    for (model.active[depth..]) |*entry| entry.* = std.mem.zeroes(@TypeOf(entry.*));
    h.auto(model);
    h.auto(src.last_non_secure);
}

/// Direct inspection of CPU1's Second private units, Pair turn/timebase state,
/// and CPU1 NVIC pending model without production snapshot codecs.
pub fn secondUnits(pair: *const Pair) Digest {
    var h: Hasher = .{};
    h.autoExcept(pair.second, .{ "state", "guard.unit" });
    var state = pair.second.state;
    const depth = @min(state.interrupts.depth, state.interrupts.active.len);
    for (state.interrupts.active[depth..]) |*entry| entry.* = std.mem.zeroes(@TypeOf(entry.*));
    h.autoExcept(state, .{ "wiring", "dividers", "timebase", "fault" });
    h.auto(if (state.dividers) |div| @as(?u16, div.*) else @as(?u16, null));
    h.boolean(state.fault != null);
    if (state.fault) |flt| {
        h.int(flt.pc);
        h.auto(flt.access);
    }
    h.autoExcept(state.timebase, .{ "per_chunk", "words" });
    h.autoExcept(pair.ns_timebase, .{ "per_chunk", "words" });
    h.int(pair.cycle_remainder);
    h.int(pair.last_ran);
    h.auto(pair.turn_state);
    hashNvicModel(&h, &pair.core.pending);
    return h.final();
}

pub fn scheduler(h_ptr: *Harness, ended: ?Ended) Digest {
    var h: Hasher = .{};
    h.auto(h_ptr.state.edge.saved);
    h.autoExcept(h_ptr.state.edge.timebase, .{ "per_chunk", "words" });
    h.autoExcept(h_ptr.state.edge.ns_timebase, .{ "per_chunk", "words" });
    h.auto(if (h_ptr.state.edge.chunk) |ch| @as(?u64, ch.mark) else @as(?u64, null));
    if (h_ptr.state.files.pair) |pair| {
        h.int(pair.second.state.ran);
        h.int(pair.cycle_remainder);
        h.int(pair.last_ran);
        h.auto(pair.turn_state);
    }
    h.auto(ended);
    return h.final();
}

/// Excludes ONLY `Units.count` (`session.live.clock` / `other.clock`) per-run
/// command bookkeeping so straight vs split vs random-budget runs match.
pub fn debugUnits(h_ptr: *Harness) !Digest {
    var h: Hasher = .{};
    const count: usize = if (h_ptr.state.files.pair != null) 2 else 1;
    h.int(@as(u8, @intCast(count)));
    for (0..count) |idx| {
        const machine = try h_ptr.session().machine(@fromBackingInt(@intCast(idx)));
        inline for (.{ "fpb", "dwt", "dcb", "unit_pending", "monitor_pending", "halting" }) |name| {
            h.auto(@field(machine, name));
        }
        var itm = machine.itm;
        const len = @min(itm.text.len, itm.text.buffer.len);
        @memset(itm.text.buffer[len..], 0);
        h.auto(itm);

        const sess = h_ptr.session();
        if (sess.live.index == idx) {
            h.boolean(sess.live.started);
            h.auto(if (sess.live.watch) |w| @as(?@TypeOf(w.driver.cycles), w.driver.cycles) else null);
        } else if (sess.live.other) |other| {
            h.boolean(other.started);
            h.auto(if (other.watch) |w| @as(?@TypeOf(w.driver.cycles), w.driver.cycles) else null);
        }
    }
    hashNvicModel(&h, &h_ptr.state.pending);
    h.auto(h_ptr.state.files.identity());
    return h.final();
}

pub fn capture(h_ptr: *Harness) !Capture {
    return captureWith(std.testing.allocator, h_ptr, null, null);
}

pub fn captureWith(
    allocator: std.mem.Allocator,
    h_ptr: *Harness,
    ended: ?Ended,
    accessor: ?ra8.session.history_incremental_restore.SpaceAccessor,
) !Capture {
    const cpu0_store = &h_ptr.state.cpu0.store.?;
    const pair = h_ptr.state.files.pair;
    const cpu1_store: ?*const ra8.chip.core.cpu.memory.store.Store = if (pair) |p| &p.store.? else null;
    return .{
        .position = h_ptr.grid().at,
        .cores = .{ core(h_ptr.primaryCpu()), if (pair) |p| core(&p.core.cpu) else null },
        .stores = .{ spaces.storeDigest(cpu0_store), if (cpu1_store) |s| spaces.storeDigest(s) else null },
        .spaces = try spaces.spacesDigest(allocator, cpu0_store, cpu1_store, h_ptr.board(), accessor),
        .aliases = spaces.aliases(cpu0_store, cpu1_store),
        .fabric = spaces.fabricDigest(cpu0_store),
        .scheduler = scheduler(h_ptr, ended),
        .second_units = if (pair) |p| secondUnits(p) else null,
        .debug_units = try debugUnits(h_ptr),
        .peripherals = try board_oracle.peripheralsDigest(allocator, h_ptr.board()),
        .attachments = attach_oracle.attachmentsDigest(h_ptr.board(), h_ptr.state.files.attachments),
    };
}
