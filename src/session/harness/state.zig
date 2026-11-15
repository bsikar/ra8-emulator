//! Heap-stable machine state and callbacks owned by a Harness.
const advance_mod = @import("advance.zig");
const Board = @import("ra8_board").board.Board;
const board_boundary = @import("../board/boundary.zig");
const BoardBus = @import("ra8_chip").core.cpu.board_bus.BoardBus;
const checkpoints = @import("checkpoints.zig");
const chunk_clock = @import("../chunk_clock.zig");
const Cpu0 = @import("ra8_board").cpu0_store.Cpu0;
const cpu_mod = @import("ra8_chip").core.cpu.cpu;
const decode = @import("ra8_chip").core.cpu.decode;
const device_metrics = @import("../device_metrics.zig");
const elf = @import("ra8_board").image.elf;
const files = @import("files.zig");
const history_trail = @import("../history/trail.zig");
const input_script = @import("ra8_components").input_script;
const LoaderState = @import("loader_state.zig").LoaderState;
const metrics = @import("metrics.zig");
const mpu_check = @import("ra8_chip").core.cpu.board_bus.mpu_check;
const NvicSource = @import("ra8_chip").core.cpu.exception.nvic_source.NvicSource;
const profile = @import("ra8_board").profile;
const QuietSource = @import("ra8_chip").core.cpu.exception.quiet_source.QuietSource;
const Reboot = @import("ra8_chip").core.reboot.Reboot;

const rtos_hook = step_hook.rtos.hook;
const rtos_publish = step_hook.rtos.publish;
const session_api = @import("../api.zig");
const session_display = @import("../board/display.zig");
const session_faults = @import("../board/faults/faults.zig");
const session_history = @import("../history.zig");
const session_plug = @import("../board/plug.zig");
const session_state = @import("../board/state.zig");
const std = @import("std");
const step_hook = @import("../step_hook.zig");
const stop_machine = @import("../stop_machine.zig");
const transport_mod = @import("../transport/transport.zig");
const txm_debug = @import("../txm/debug.zig");
const txm_publish = @import("../txm/publish.zig");
const watch_bus = @import("../watch/bus.zig");
const window_box = @import("window.zig");

pub const State = struct {
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
    /// CPU0's decoded instructions and formed blocks, as a plain run keeps them
    /// (boot.zig runOn), so a session runs at a plain run's pace (RA8EMU-1120).
    decoded: decode.cache.DecodeCache,
    formed: *decode.block_cache.BlockCache,
    pending: NvicSource,
    quiet: QuietSource,
    loading: LoaderState,
    session: session_api.Session,
    /// The control plane the front ends drive; rebuilt live, never saved.
    transport: transport_mod.Transport,
    plugs_arena: std.heap.ArenaAllocator,
    plugs: session_plug.Plugs,
    faults: session_faults.Faults,
    edge: board_boundary.BoardBoundary,
    chunk: chunk_clock.ChunkClock,
    files: session_state.Files,
    state_file: files.StateFile,
    history: session_history.History,
    /// The input landing adapter (slice 16) and its observer: board dispatches
    /// report through it, and the boundary's saved state carries its position.
    landing: session_history.Landing,
    landing_observer: input_script.Script.Landing,
    /// The undo trail while a run records, null until `record` starts it.
    recording: ?history_trail.Recording = null,
    /// The reverse window recording the live run, once `openWindow` built it.
    window: ?*window_box.Window = null,
    /// The armed checkpoint pair when the application bound a host history root.
    persistent: ?*checkpoints.Armed = null,
    reboot: Reboot,
    display: session_display.Host,
    metrics_tracking: [2]metrics.Track,
    tracer: ?rtos_hook.Tracer,
    listener: rtos_hook.zig.Listener,
    publisher: rtos_publish.Publisher,
    module_watch: txm_publish.Watcher,
    /// Set by watchModules and pairModules; the state is built without defaults.
    modules: txm_debug.Table,

    pub fn metricsRead(context: *anyopaque, core: u1) device_metrics.Snapshot {
        const self: *State = @ptrCast(@alignCast(context));
        return metrics.read(self, core);
    }

    pub fn advance(context: *anyopaque, max_ns: u64) anyerror!void {
        const self: *State = @ptrCast(@alignCast(context));
        try advance_mod.run(&self.session, &self.board, &self.edge, max_ns);
    }
};
