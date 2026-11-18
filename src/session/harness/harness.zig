//! Public owner for a firmware image, its Zig core, board, and debug session.
const board_api = @import("ra8_board");
const metrics = @import("metrics.zig");
const recording = @import("recording.zig");
const snapshot_inventory = @import("snapshot_inventory.zig");

const std = @import("std");

const Board = @import("ra8_board").board.Board;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const debug_session = @import("../session.zig");
const dwt = @import("ra8_chip").periph.dwt;
const elf = @import("ra8_board").image.elf;
pub const files = @import("files.zig");
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const input_script = @import("ra8_components").input_script;
const option_memory = @import("ra8_chip").periph.iwdt.option_memory;
const profile = @import("ra8_board").profile;
const scheduler = @import("ra8_chip").core.scheduler;
const second_core = @import("ra8_chip").core.second.core;
const session_api = @import("../api.zig");
const session_display = @import("../board/display.zig");
const session_events = @import("../board/events.zig");
const session_faults = @import("../board/faults/faults.zig");
const session_history = @import("../history.zig");
const session_plug = @import("../board/plug.zig");
const session_state = @import("../board/state.zig");
const transport_mod = @import("../transport/transport.zig");

const block_cache = @import("block_cache.zig");
pub const checkpoints = @import("checkpoints.zig");
const load_input = @import("load_input.zig");
const rtos_trace = @import("rtos_trace.zig");
pub const stacks = @import("stacks.zig");
const symbols = @import("../symbols.zig");
const txm_debug = @import("../txm/debug.zig");
const txm_modules = @import("../txm/modules.zig");
const txm_publish = @import("../txm/publish.zig");

pub const limits = struct {
    pub const max_elf_bytes = 64 * 1024 * 1024;
    pub const max_input_bytes = 1024 * 1024;
};

pub const Options = @import("options.zig").Options;

const LoaderState = @import("loader_state.zig").LoaderState;

const State = @import("state.zig").State;

comptime {
    if (!snapshot_inventory.complete(State)) @compileError("unclassified harness State");
}
/// Owns the heap-stable emulator state. Do not copy a live Harness value.
pub const Harness = struct {
    state: *State,

    pub fn session(self: *Harness) *session_api.Session {
        return &self.state.session;
    }

    /// The control plane front ends command and pump; the harness owns it
    /// beside the Session (time-travel design section 3).
    pub fn transport(self: *Harness) *transport_mod.Transport {
        return &self.state.transport;
    }

    pub fn image(self: *const Harness) elf.Image {
        return self.state.image;
    }

    /// The image a core last loaded (the opened one, until a session load
    /// replaces it), or null when nothing loaded on that core.
    pub fn loadedImage(self: *const Harness, core: session_api.Core) ?elf.Image {
        const bytes = self.state.loading.loaded[@backingInt(core)] orelse return null;
        return elf.Image.init(bytes) catch null;
    }

    pub fn board(self: *Harness) *Board {
        return &self.state.board;
    }

    /// The board profile this harness opened with (RA8EMU-1152).
    pub fn boardProfile(self: *Harness) *const profile.Profile {
        return &self.state.profile;
    }

    pub fn guest(self: *Harness) Guest {
        return self.state.cpu0.own();
    }

    pub fn primaryCpu(self: *Harness) *cpu_mod.Cpu {
        return &self.state.cpu;
    }

    pub fn attachCore(self: *Harness, core: session_api.Core, cpu: *cpu_mod.Cpu, core_guest: Guest) void {
        const index = @backingInt(core);
        self.state.loading.cpu[index] = cpu;
        self.state.loading.memory[index] = core_guest;
        self.state.session.attachBoard(core, self.state.board.ticker(), core_guest);
    }

    pub const traceRtos = rtos_trace.traceRtos;
    pub const observeRtos = rtos_trace.observeRtos;
    pub const traceIfRtos = rtos_trace.traceIfRtos;

    /// The scheduler state the run's positions are read from, and the
    /// retired-slot counter of CPU0 that moves through it.
    pub fn grid(self: *Harness) *const scheduler.State {
        return &self.state.edge.saved;
    }

    /// Sample CPU0's call stacks into `into` (RA8EMU-833), named by the
    /// opened image and tagged with the thread when traceRtos() found one.
    /// `into` stays put until `unsampleStacks` or deinit.
    pub fn sampleStacks(self: *Harness, into: *stacks.Stacks) void {
        const state = self.state;
        const trace = if (state.tracer) |*found| &found.trace else null;
        into.watch(0, &state.cpu, &state.image, &state.board.time.base, trace);
    }

    pub fn unsampleStacks(self: *Harness, into: *stacks.Stacks) void {
        into.unwatch(0, &self.state.cpu);
    }

    /// Publish ThreadX module loads, unloads and faults on the session's event
    /// stream (RA8EMU-1139), read from the Module Manager's list at each
    /// chunk boundary. False when the image has no Module Manager; call
    /// once, after open.
    pub fn watchModules(self: *Harness) bool {
        const state = self.state;
        const head = symbols.addressOf(state.image, txm_modules.list_symbol) orelse return false;
        state.module_watch = .{
            .head_at = head,
            .memory = .{ .guest = self.guest() },
            .stream = &state.session.event_stream,
            .inner = state.session.live.boundary,
            .time = &state.board.time.base,
        };
        state.module_watch.fault_at = symbols.addressOf(state.image, txm_publish.fault_symbol);
        state.modules = .{ .pairs = &.{} };
        state.module_watch.table = &state.modules;
        state.session.live.boundary = state.module_watch.hook();
        return true;
    }

    /// The module ELFs `--app FILE.ra8app=MODULE.elf` paired (RA8EMU-1141),
    /// placed as their modules load; `pairs` outlives the harness.
    pub fn pairModules(self: *Harness, pairs: []const txm_debug.Pair) *txm_debug.Table {
        self.state.modules = .{ .pairs = pairs };
        return &self.state.modules;
    }

    /// The board's plug hook, which also keeps what is fitted where.
    pub fn plugs(self: *Harness) *session_plug.Plugs {
        return &self.state.plugs;
    }

    pub fn stateFiles(self: *Harness) session_state.Hook {
        return self.state.state_file.hook();
    }

    /// The rewind history this run records (RA8EMU-1170).
    pub fn history(self: *Harness) *session_history.History {
        return &self.state.history;
    }

    /// Keep snapshots under `dir` (RA8EMU-1175); null returns to the working
    /// directory. `dir` must outlive the harness.
    pub fn setStateDir(self: *Harness, dir: ?[]const u8) void {
        self.state.state_file.dir = dir;
    }

    /// Let the boundary tick CPU1's board edge and take its reset requests,
    /// and let snapshots save its run state.
    pub fn bindSecondDriver(self: *Harness, pair: *second_core.zig.run.Driver) void {
        self.state.edge.second = &pair.second;
        self.state.edge.second_memory = pair.guest();
        self.state.files.pair = pair;
        if (self.state.window) |held| held.attachSecond(&pair.core.cpu.slots);
    }

    /// Starts recording the undo trail on the machine's store, the round
    /// facts read live (RA8EMU-D1). Both cores and the store must be
    /// attached, since the trail attributes a write by its core's slot count.
    pub const record = recording.record;

    /// Builds the reverse window of `bytes` budget, plants it at the loaded
    /// machine and records the live run into it from here on. Call once.
    pub const openWindow = recording.openWindow;

    pub fn deinit(self: *Harness) void {
        const state = self.state;
        if (state.persistent) |held| held.recorder.force() catch {};
        if (state.window) |held| held.destroy();
        state.display.deinit();
        state.plugs.deinit();
        state.plugs_arena.deinit();
        block_cache.drop(state.formed, state.cpu0.own().store.fanMut());
        if (state.recording) |*held| held.deinit();
        if (state.persistent) |held| checkpoints.disarmSession(state.allocator, &state.session, &state.history, held);
        state.session.releaseReplay();
        state.cpu0.close();
        state.board.deinit();
        state.loading.deinit();
        state.history.deinit();
        state.allocator.free(state.bytes);
        state.allocator.destroy(state);
        self.* = undefined;
    }
};

/// Open and load one ELF with the board ticker and display attached.
pub fn open(allocator: std.mem.Allocator, io: std.Io, options: Options) !Harness {
    if (options.settle_window_ns == 0) return error.InvalidSettleWindow;
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    state.allocator = allocator;
    state.recording = null;
    state.window = null;
    state.persistent = null;
    state.bytes = if (options.elf_bytes) |bytes|
        try allocator.dupe(u8, bytes)
    else blk: {
        const ops = options.files orelse return error.NoFileOps;
        break :blk try ops.reader.readAlloc(io, options.elf_path, allocator, limits.max_elf_bytes);
    };
    errdefer allocator.free(state.bytes);
    state.image = try elf.Image.init(state.bytes);
    state.board = Board.init(allocator);
    errdefer state.board.deinit();
    const chosen = options.resolvedMachine();
    state.board.machine = chosen;
    state.board.part = chosen.part;
    state.profile = try profile.parse(options.board_profile orelse profile.ek_ra8d2);
    state.board.external_memory = state.profile.memory;
    try state.board.nor.resize(state.profile.memory.ospi.size);
    state.board.clock.pace.mode = .virtual;
    state.board.panel_vsync = options.panel_vsync;
    try load_input.load(allocator, io, options.files, &state.board, options.input_script, options.input_script_bytes);
    state.cpu0 = .{};
    state.tracer = null;
    state.metrics_tracking = .{ .{}, .{} };
    errdefer state.cpu0.close();
    _ = try state.cpu0.attachStore(&state.board, state.image);
    const vector = state.image.vectorBaseFor(state.board.desc().memory) orelse return error.NoVectorTable;
    option_memory.apply(&state.board.heartbeat, state.cpu0.own());
    const primary = chosen.primary();
    state.memory = .{
        .memory = .{ .store = .{ .store = &state.cpu0.store.?, .initiator = .cpu0 } },
        .periph = &state.board.bus,
        .scs = .{
            .partitions = if (primary.security) &state.board.partitions else null,
            .regions = &state.board.regions,
            .clears = &state.board.clears,
        },
    };
    // The MPU check, as a plain run arms it (boot.zig), before any view copies
    // the direct path; without it a session core refused nothing (RA8EMU-1148).
    state.check = .{ .unit = &state.board.regions, .state = &state.cpu.banked.current };
    state.memory.armCheck(&state.check);
    state.machine = .{ .dwt = .{ .numcomp = dwt.numcompOf(primary.cpuid) } };
    state.driver = .{ .machine = &state.machine };
    state.watching = .{ .inner = state.memory.view(), .driver = &state.driver };
    state.pending = .{};
    state.quiet = .{ .inner = state.pending.source(), .memory = state.watching.view() };
    state.cpu = .{ .bus = state.quiet.bus(), .source = state.quiet.source(), .quiet = &state.quiet };
    state.cpu.profile = primary.profile;
    state.cpu.mpu = &state.check;
    state.pending.banked = &state.cpu.banked;
    state.pending.clear_due = &state.quiet.clear_due;
    state.decoded = .{};
    state.cpu.decoded = &state.decoded;
    state.formed = try block_cache.form(state.cpu0.own().store.fanMut());
    errdefer block_cache.drop(state.formed, state.cpu0.own().store.fanMut());
    state.cpu.blocks = state.formed;
    // CPACR and the FP context words reach the core's FP state (boot.zig), else NOCP (RA8EMU-950).
    state.memory.scs.fp = &state.cpu.fp;
    try state.cpu.reset(vector);
    state.loading = .{ .allocator = allocator };
    errdefer state.loading.deinit();
    state.loading.cpu[0] = &state.cpu;
    state.loading.memory[0] = state.cpu0.own();
    state.reboot = .{ .vector_base = vector };
    try wire(state, allocator, io, options);
    return .{ .state = state };
}

/// Assemble the session around the wired cores: hooks, history, display, and
/// the opened image's initial load.
fn wire(state: *State, allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    state.session = .{
        .live = .{
            .core = .{ .cpu = &state.cpu },
            .machine = &state.machine,
            .budget = debug_session.limits.default_budget,
            .watch = &state.watching,
        },
        .machine_desc = options.resolvedMachine(),
    };
    state.session.metrics = .{ .context = state, .readFn = State.metricsRead };
    state.transport = .{ .session = &state.session };
    state.session.attachInputScript(&state.board.input_script);
    state.session.attachLoader(.{ .context = &state.loading, .loadFn = LoaderState.load });
    state.plugs_arena = std.heap.ArenaAllocator.init(allocator);
    errdefer state.plugs_arena.deinit();
    state.plugs = session_plug.Plugs.init(&state.board, state.plugs_arena.allocator());
    state.session.attachPlugs(state.plugs.hook());
    state.faults = session_faults.Faults.init(&state.board, state.plugs_arena.allocator());
    state.session.attachFaults(&state.faults);
    state.board.reboot = &state.reboot;
    state.loading.reboot = &state.reboot;
    state.chunk = .{ .cpu = &state.cpu, .mark = state.cpu.retired };
    state.session.event_sources.chunk = &state.chunk;
    state.edge = .{
        .board = &state.board,
        .core = state.cpu0.own(),
        .cpu = &state.cpu,
        .reboot = &state.reboot,
        .selected = &state.session.live.index,
        .chunk = &state.chunk,
        .idle_skip = options.idle_skip,
    };
    state.session.live.boundary = state.edge.hook();
    state.landing = .{ .history = &state.history, .grid = &state.edge.saved };
    state.landing_observer = state.landing.observer();
    state.board.input_landing = &state.landing_observer;
    bindSnapshot(state, allocator, io, options);
    state.history = try session_history.History.init(allocator, &state.files, options.history_frames);
    errdefer state.history.deinit();
    state.session.history = &state.history;
    session_events.attach(&state.board, &state.session);
    state.session.attachBoard(.cpu0, state.board.ticker(), state.cpu0.own());
    state.display = session_display.Host.init(
        allocator,
        &state.board,
        .{ .context = state, .advanceFn = State.advance, .session = &state.session },
    );
    errdefer state.display.deinit();
    state.display.settled.window_ns = options.settle_window_ns;
    state.display.watch.events = &state.session.event_sources;
    state.display.watch.useIo(io);
    state.session.attachDisplay(state.display.interface());
    try state.session.load(.cpu0, state.bytes);
    if (options.history_storage != null and options.history_objects != null and options.checkpoint_every != 0) {
        state.persistent = try checkpoints.armSession(
            allocator,
            &state.session,
            &state.history,
            &state.files,
            &state.edge.saved,
            options.history_storage.?,
            options.history_objects.?,
            options.history_disk,
            options.history_checkpoint_cap,
            options.checkpoint_every,
        );
    }
}

fn bindSnapshot(state: *State, allocator: std.mem.Allocator, io: std.Io, options: Options) void {
    state.files = .{
        .store = &state.cpu0.store.?,
        .cpu = &state.cpu,
        .board = &state.board,
        .edge = &state.edge,
        .session = &state.session,
        .image = state.bytes,
        .image_hash = board_api.snapshot.run.imageIdentity(state.bytes),
        .images = &state.loading.loaded,
        .hashes = &state.loading.hashes,
        .pending = &state.pending,
        .attachments = .{
            .arena = &state.plugs_arena,
            .plugs = &state.plugs,
            .faults = &state.faults,
        },
    };
    state.state_file = .{
        .allocator = allocator,
        .io = io,
        .files = &state.files,
        .dir = options.state_dir,
        .store = if (options.files) |ops| ops.state else null,
    };
}
