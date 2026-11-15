//! Bind application callbacks to a Session without invoking them.
const api = @import("api.zig");

const board_faults = @import("board/faults/faults.zig");
const chip = @import("ra8_chip");
const history_recorder = @import("history/recorder.zig");
const history_root = @import("history/root.zig");
const input_script = @import("ra8_components").input_script;
const session_fork = @import("fork.zig");

const BoardTick = chip.core.tick.Tick;
const Guest = chip.core.cpu.memory.guest.Guest;
const TimeBase = chip.periph.timebase.TimeBase;

pub fn attachLoader(self: *api.Session, loader: api.Loader) void {
    self.loader = loader;
}

pub fn attachEventClock(self: *api.Session, clock: api.EventClock) void {
    self.event_clock = clock;
}

pub fn attachGraphSink(self: *api.Session, sink: api.GraphSink) void {
    self.graph_sink = sink;
}

pub fn attachNet(self: *api.Session, hook: api.NetHook) void {
    self.net_hook = hook;
}

pub fn attachConsole(self: *api.Session, hook: api.ConsoleHook) void {
    self.console_hook = hook;
}

pub fn attachCamera(self: *api.Session, hook: api.CameraHook) void {
    self.camera_hook = hook;
}

pub fn attachPlugs(self: *api.Session, hook: api.PlugHook) void {
    self.plugs = hook;
}

pub fn attachTimeBase(self: *api.Session, time_base: *const TimeBase) void {
    self.time_base = time_base;
    self.event_sources.bind(&self.event_stream, time_base);
}

pub fn attachInputScript(self: *api.Session, script: *input_script.Script) void {
    self.input_script = script;
}

pub fn attachBoard(self: *api.Session, core: api.Core, tick: BoardTick, guest: Guest) void {
    self.board_ticks[@backingInt(core)] = .{ .tick = tick, .guest = guest };
}

pub fn attachDisplay(self: *api.Session, d: api.Display) void {
    self.display = d;
}

pub fn attachFaults(self: *api.Session, faults: *board_faults.Faults) void {
    self.faults = faults;
}

pub fn attachForkRouter(self: *api.Session, router: *session_fork.ForkRouter) void {
    self.fork_router = router;
}

pub fn attachNewHistory(self: *api.Session, hook: session_fork.fork_types.NewHistoryHook) void {
    self.new_history = hook;
}

pub fn attachRoot(self: *api.Session, r: *const history_root.Root) void {
    self.root = r;
}

pub fn attachImageIdentity(self: *api.Session, core: api.Core, id: [16]u8) void {
    self.image_identity[@as(usize, @backingInt(core))] = id;
}

pub fn attachPersistentRecorder(self: *api.Session, rec: *history_recorder.Recorder) void {
    self.persistent_recorder = rec;
}

pub fn attachAsyncQueue(self: *api.Session, queue: api.AsyncQueue) void {
    self.async_traffic.queue = queue;
}
