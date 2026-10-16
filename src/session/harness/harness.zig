//! Public owner for a firmware image, its Zig core, board, and debug session.
const std = @import("std");
const elf = @import("ra8_board").image.elf;
const part = @import("ra8_chip").core.part;
const glcdc_vsync = @import("ra8_chip").periph.glcdc.vsync;
const BoardBus = @import("ra8_chip").core.cpu.board_bus.BoardBus;
const mpu_check = @import("ra8_chip").core.cpu.board_bus.mpu_check;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const NvicSource = @import("ra8_chip").core.cpu.exception.nvic_source.NvicSource;
const QuietSource = @import("ra8_chip").core.cpu.exception.quiet_source.QuietSource;
const Guest = @import("ra8_chip").core.cpu.memory.guest.Guest;
const memory_load = @import("ra8_chip").core.cpu.memory.load;
const read_image = @import("ra8_board").image.load;
const Board = @import("ra8_board").board.Board;
const profile = @import("ra8_board").profile;
const option_memory = @import("ra8_chip").periph.iwdt.option_memory;
const Reboot = @import("ra8_chip").core.reboot.Reboot;
const session_plug = @import("../board/plug.zig");
const session_faults = @import("../board/faults/faults.zig");
const board_boundary = @import("../board/boundary.zig");
const session_events = @import("../board/events.zig");
const second_core = @import("ra8_chip").core.second.core;
const memmap = @import("ra8_chip").core.memmap;
const session_display = @import("../board/display.zig");
const session_state = @import("../board/state.zig");
const session_history = @import("../history.zig");
const history_trail = @import("../history/trail.zig");
const chunk_clock = @import("../chunk_clock.zig");
pub const files = @import("files.zig");
const debug_session = @import("../session.zig");
const session_api = @import("../api.zig");
const stop_machine = @import("../stop_machine.zig");
const step_hook = @import("../step_hook.zig");
const watch_bus = @import("../watch/bus.zig");
const rtos_hook = step_hook.rtos.hook;
const rtos_publish = step_hook.rtos.publish;
const symbols = @import("../symbols.zig");
const txm_modules = @import("../txm/modules.zig");
const txm_publish = @import("../txm/publish.zig");
const txm_debug = @import("../txm/debug.zig");
const Cpu0 = @import("ra8_board").cpu0_store.Cpu0;
const decode = @import("ra8_chip").core.cpu.decode;
pub const stacks = @import("stacks.zig");
const load_input = @import("load_input.zig");
const block_cache = @import("block_cache.zig");

pub const limits = struct {
    pub const max_elf_bytes = 64 * 1024 * 1024;
    pub const max_input_bytes = 1024 * 1024;
};

pub const Options = struct {
    elf_path: []const u8,
    device: part.Part = .ra8p1,
    input_script: ?[]const u8 = null,
    /// The board profile's text (RA8EMU-1152); null is the shipped EK-RA8D2
    /// default. Its labels point into the caller's text and outlive it.
    board_profile: ?[]const u8 = null,
    /// Where snapshots live (RA8EMU-1175); null keeps bare names in the working directory.
    state_dir: ?[]const u8 = null,
    /// How many stops the rewind history keeps (RA8EMU-1170); the oldest falls off past it.
    history_frames: u32 = 240,
    settle_window_ns: u64 = 50_000_000,
    /// Whether the boundary stretches across idle sleeps (RA8EMU-1120).
    idle_skip: bool = true,
    /// The run's `panel_vsync` config (RA8EMU R9), stored the way a plain run's fit stores it.
    panel_vsync: ?glcdc_vsync.Config = null,
    /// The host directory the run's file reads and writes open against
    /// (RA8EMU-968); null falls back to the process cwd for host tests.
    root: ?std.Io.Dir = null,
    /// The directory host file access resolves through, never `cwd()` directly.
    pub fn host(self: Options) std.Io.Dir {
        return self.root orelse std.Io.Dir.cwd();
    }
};

const LoaderState = @import("loader_state.zig").LoaderState;

const State = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    image: elf.Image,
    board: Board,
    /// The board profile the run opened with, its labels pointing into the
    /// caller's text (RA8EMU-1152).
    profile: profile.Profile = undefined,
    cpu0: Cpu0,
    memory: BoardBus,
    /// CPU0's MPU check, armed as a plain run arms it (boot.zig).
    check: mpu_check.Check,
    machine: stop_machine.Machine,
    driver: step_hook.Driver,
    watching: watch_bus.WatchBus,
    cpu: cpu_mod.Cpu,
    /// CPU0's decoded instructions and formed blocks, as a plain run keeps
    /// them (boot.zig runOn), so a session runs at a plain run's pace
    /// (RA8EMU-1120).
    decoded: decode.cache.DecodeCache,
    formed: *decode.block_cache.BlockCache,
    pending: NvicSource,
    quiet: QuietSource,
    loading: LoaderState,
    session: session_api.Session,
    plugs_arena: std.heap.ArenaAllocator,
    plugs: session_plug.Plugs,
    faults: session_faults.Faults,
    edge: board_boundary.BoardBoundary,
    chunk: chunk_clock.ChunkClock,
    files: session_state.Files,
    state_file: files.StateFile,
    history: session_history.History,
    /// The undo trail while a run records, null until `record` starts it.
    recording: ?history_trail.Recording = null,
    reboot: Reboot,
    display: session_display.Host,
    tracer: ?rtos_hook.Tracer,
    listener: rtos_hook.zig.Listener,
    publisher: rtos_publish.Publisher,
    module_watch: txm_publish.Watcher,
    /// Set by watchModules and pairModules; the state is built without defaults.
    modules: txm_debug.Table,

    fn advance(context: *anyopaque, max_ns: u64) anyerror!void {
        const self: *State = @ptrCast(@alignCast(context));
        const selected = self.session.currentCore();
        try self.session.switchTo(.cpu0);
        defer self.session.switchTo(selected) catch {};
        const deadline = (try self.session.now()) +| max_ns;
        const budget = self.session.live.budget;
        defer self.session.live.budget = budget;
        while ((try self.session.now()) < deadline) {
            const remaining = self.board.time.base.cyclesUntil(deadline) -| self.edge.saved.stretch.carry;
            self.session.live.budget = @max(1, @min(budget, remaining));
            const before = try self.session.now();
            _ = try self.session.run(.cpu0, .cont);
            if ((try self.session.now()) <= before) return error.NoVirtualProgress;
        }
    }
};

comptime {
    if (!@import("snapshot_inventory.zig").complete(State)) @compileError("unclassified harness State");
}
/// Owns the heap-stable emulator state. Do not copy a live Harness value.
pub const Harness = struct {
    state: *State,

    pub fn session(self: *Harness) *session_api.Session {
        return &self.state.session;
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

    /// Publish CPU0's ThreadX switches and exception entry and return on
    /// the session's event stream (RA8EMU-346). The tracer sits in front of
    /// the core and is drained at each chunk boundary. Stamps are CPU0's
    /// retired instructions, one cycle each, at the time base's rate. False
    /// when the image has no ThreadX; call once, after open.
    pub fn traceRtos(self: *Harness) bool {
        const state = self.state;
        state.tracer = rtos_hook.resolve(state.image, .{}) orelse return false;
        const tracer = &state.tracer.?;
        tracer.now = &state.board.time.base.retired;
        tracer.trace.fine = &state.cpu.retired;
        state.listener = .{ .tracer = tracer };
        state.cpu.bus = state.listener.onBus(state.cpu.bus);
        if (state.cpu.source) |inner| state.cpu.source = state.listener.onSource(inner);
        state.publisher = .{ .trace = &tracer.trace, .stream = &state.session.event_stream, .inner = state.session.live.boundary, .time = &state.board.time.base };
        state.session.live.boundary = state.publisher.hook();
        return true;
    }

    /// Turn RTOS tracing on unless it already is; false when the image
    /// has no ThreadX current-thread pointer to trace.
    pub fn traceIfRtos(self: *Harness) bool {
        if (self.state.tracer != null) return true;
        return self.traceRtos();
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
        state.module_watch = .{ .head_at = head, .memory = .{ .guest = self.guest() }, .stream = &state.session.event_stream, .inner = state.session.live.boundary, .time = &state.board.time.base };
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

    /// Snapshot and restore of this run's file (RA8EMU-768).
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
    }

    /// Starts recording the undo trail: one tap on the machine's store,
    /// the round facts read live (RA8EMU-D1). The store's writes and the
    /// core's fast path feed the trail through that one hook; a borrower
    /// store follows its lender's. Both cores and the machine store must
    /// be attached, because the trail attributes every write by the
    /// writing core's live slot count.
    pub fn record(self: *Harness) !void {
        const state = self.state;
        const cpu0 = state.loading.cpu[0] orelse return error.CoreNotAttached;
        const cpu1 = state.loading.cpu[1] orelse return error.CoreNotAttached;
        if (state.cpu0.store == null) return error.StoreMissing;
        state.recording = history_trail.Recording.init(
            state.allocator,
            .{ &cpu0.slots, &cpu1.slots },
            &state.cpu0.store.?,
        );
        state.recording.?.arm();
    }

    pub fn deinit(self: *Harness) void {
        const state = self.state;
        state.display.deinit();
        state.plugs.deinit();
        state.plugs_arena.deinit();
        block_cache.drop(state.formed, state.cpu0.own().store.fanMut());
        if (state.recording) |*held| held.deinit();
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
    state.bytes = try options.host().readFileAlloc(io, options.elf_path, allocator, .limited(limits.max_elf_bytes));
    errdefer allocator.free(state.bytes);
    state.image = try elf.Image.init(state.bytes);
    state.board = Board.init(allocator);
    errdefer state.board.deinit();
    state.board.part = options.device;
    state.profile = try profile.parse(options.board_profile orelse profile.ek_ra8d2);
    state.board.external_memory = state.profile.memory;
    try state.board.nor.resize(state.profile.memory.ospi.size);
    state.board.clock.pace.mode = .virtual;
    state.board.panel_vsync = options.panel_vsync;
    try load_input.load(allocator, io, options.host(), &state.board, options.input_script);
    state.cpu0 = .{};
    state.tracer = null;
    errdefer state.cpu0.close();
    _ = try state.cpu0.attachStore(&state.board, state.image);
    const vector = state.image.vectorBase() orelse return error.NoVectorTable;
    option_memory.apply(&state.board.heartbeat, state.cpu0.own());
    state.memory = .{ .memory = .{ .store = .{ .store = &state.cpu0.store.?, .initiator = .cpu0 } }, .periph = &state.board.bus, .scs = .{ .partitions = &state.board.partitions, .regions = &state.board.regions, .clears = &state.board.clears } };
    // The MPU check, as a plain run arms it (boot.zig), before any view copies
    // the direct path; without it a session core refused nothing (RA8EMU-1148).
    state.check = .{ .unit = &state.board.regions, .state = &state.cpu.banked.current };
    state.memory.armCheck(&state.check);
    state.machine = .{};
    state.driver = .{ .machine = &state.machine };
    state.watching = .{ .inner = state.memory.view(), .driver = &state.driver };
    state.pending = .{};
    state.quiet = .{ .inner = state.pending.source(), .memory = state.watching.view() };
    state.cpu = .{ .bus = state.quiet.bus(), .source = state.quiet.source(), .quiet = &state.quiet };
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
    state.session = .{ .live = .{ .core = .{ .cpu = &state.cpu }, .machine = &state.machine, .budget = debug_session.limits.default_budget, .watch = &state.watching } };
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
    state.edge = .{ .board = &state.board, .core = state.cpu0.own(), .cpu = &state.cpu, .reboot = &state.reboot, .selected = &state.session.live.index, .chunk = &state.chunk, .idle_skip = options.idle_skip };
    state.session.live.boundary = state.edge.hook();
    state.files = .{ .store = &state.cpu0.store.?, .cpu = &state.cpu, .board = &state.board, .edge = &state.edge, .session = &state.session, .image = state.bytes, .images = &state.loading.loaded, .pending = &state.pending, .attachments = .{ .arena = &state.plugs_arena, .plugs = &state.plugs, .faults = &state.faults } };
    state.state_file = .{ .allocator = allocator, .io = io, .files = &state.files, .dir = options.state_dir, .root = options.root };
    state.history = try session_history.History.init(allocator, &state.files, options.history_frames);
    state.session.history = &state.history;
    session_events.attach(&state.board, &state.session);
    state.session.attachBoard(.cpu0, state.board.ticker(), state.cpu0.own());
    state.display = session_display.Host.init(allocator, &state.board, .{ .context = state, .advanceFn = State.advance, .session = &state.session });
    errdefer state.display.deinit();
    state.display.settled.window_ns = options.settle_window_ns;
    state.display.watch.events = &state.session.event_sources;
    state.display.watch.useIo(io);
    state.session.attachDisplay(state.display.interface());
    try state.session.load(.cpu0, state.bytes);
}
