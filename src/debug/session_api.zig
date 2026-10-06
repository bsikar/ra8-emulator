//! The core-addressed debugger API, shared by the script and GDB fronts.
//!
//! It keeps image construction with the board front end, but every operation
//! on a loaded image goes through this interface and names CPU0 or CPU1.
const std = @import("std");
const debug_session = @import("session.zig");
const stop_machine = @import("stop_machine.zig");
const itm = @import("itm.zig");
const breakpoint = @import("breakpoint.zig");
const core_view = @import("core_view.zig");
const watch_table = @import("watch_table.zig");
const zig_drive = @import("zig_drive.zig");
const zig_session = @import("zig_session.zig");
const input_script = @import("../periph/i3c/i3c_input_script.zig");
const gt911 = @import("../periph/i3c/i3c_gt911.zig");
const BoardTick = @import("../core/tick.zig").Tick;
const Guest = @import("../core/cpu/memory/guest.zig").Guest;
const session_display = @import("session_display.zig");
const endpoint = @import("../periph/model/endpoint.zig");
const fault_spec = @import("../periph/model/fault_spec.zig");
const TimeBase = @import("../periph/time/timebase.zig").TimeBase;
const elf = @import("../core/elf.zig");
const symbols = @import("symbols.zig");
const widget_tree = @import("widget_tree.zig");
const session_speed = @import("session_speed.zig");
const event_sources = @import("session_event_sources.zig");

pub const Core = @import("session_event_stream.zig").Core;
pub const EventStream = @import("session_event_stream.zig").Stream;
pub const Error = error{ CoreNotAttached, NoLoader, NoInput, NoFaults, NoPlugs, NoTime, TooManyListeners };
pub const Run = zig_session.Command;
pub const Ended = zig_drive.Ended;
pub const BreakId = @import("break_table.zig").Id;
pub const WatchId = watch_table.Id;
pub const Register = core_view.Cortex;
pub const Button = input_script.Button;
pub const Frame = session_display.Frame;
pub const Widget = widget_tree.Widget;

pub const Loader = struct {
    context: *anyopaque,
    loadFn: *const fn (*anyopaque, Core, []const u8) anyerror!void,
};

/// Sets or clears (null) a fault mode on a part the board has on `at`
/// (RA8EMU-520). The board owns the parts, so it does the wrapping.
pub const FaultHook = struct {
    context: *anyopaque,
    setFn: *const fn (*anyopaque, endpoint.Endpoint, ?fault_spec.Mode) anyerror!void,
};
/// Puts the catalog part `name` on `at`, or takes whatever is there off it
/// when `name` is null (RA8EMU-212). The board owns the lines, so it plugs.
pub const PlugHook = struct {
    context: *anyopaque,
    plugFn: *const fn (*anyopaque, endpoint.Endpoint, ?[]const u8) anyerror!void,
};
pub const Endpoint = endpoint.Endpoint;
pub const FaultMode = fault_spec.Mode;
pub const SpeedHook = session_speed.Hook;

pub const Event = @import("session_event_stream.zig").Event;

pub const Listener = struct {
    context: *anyopaque,
    receive: *const fn (*anyopaque, Event) void,
};

pub const limits = struct {
    pub const listeners: usize = 8;
};

const BoardRun = struct { tick: BoardTick, guest: Guest };

pub const Session = struct {
    live: zig_session.ZigSession,
    time_base: ?*const TimeBase = null,
    loader: ?Loader = null,
    input_script: ?*input_script.Script = null,
    board_ticks: [2]?BoardRun = .{ null, null },
    display: ?session_display.Display = null,
    faults: ?FaultHook = null,
    plugs: ?PlugHook = null,
    speed: ?SpeedHook = null,
    widget_tree_addresses: [2]?u32 = .{ null, null },
    listeners: [limits.listeners]?Listener = [_]?Listener{null} ** limits.listeners,
    event_stream: EventStream = .{},
    event_sources: event_sources.Sources = .{},

    pub fn attachLoader(self: *Session, loader: Loader) void {
        self.loader = loader;
    }
    pub fn attachTimeBase(self: *Session, time_base: *const TimeBase) void {
        self.time_base = time_base;
        self.event_sources.bind(&self.event_stream, time_base);
    }
    /// Virtual nanoseconds since the attached board began its run.
    pub fn now(self: *const Session) Error!u64 {
        return (self.time_base orelse return Error.NoTime).now();
    }
    pub fn attachInputScript(self: *Session, script: *input_script.Script) void {
        self.input_script = script;
    }

    pub fn attachBoard(self: *Session, core: Core, tick: BoardTick, guest: Guest) void {
        self.board_ticks[@intFromEnum(core)] = .{ .tick = tick, .guest = guest };
    }

    pub fn attachDisplay(self: *Session, display: session_display.Display) void {
        self.display = display;
    }
    pub fn attachFaults(self: *Session, hook: FaultHook) void {
        self.faults = hook;
    }

    /// Put the part on `at` into `mode` from now on, mid-run included.
    pub fn setFault(self: *Session, core: Core, at: Endpoint, mode: FaultMode) anyerror!void {
        const hook = self.faults orelse return Error.NoFaults;
        try hook.setFn(hook.context, at, mode);
        self.publish(.{ .core = core, .kind = .fault_set });
    }

    /// Let the part on `at` behave like the part again.
    pub fn clearFault(self: *Session, core: Core, at: Endpoint) anyerror!void {
        const hook = self.faults orelse return Error.NoFaults;
        try hook.setFn(hook.context, at, null);
        self.publish(.{ .core = core, .kind = .fault_cleared });
    }

    pub fn attachPlugs(self: *Session, hook: PlugHook) void {
        self.plugs = hook;
    }

    pub fn plug(self: *Session, core: Core, at: Endpoint, name: []const u8) anyerror!void {
        const hook = self.plugs orelse return Error.NoPlugs;
        try hook.plugFn(hook.context, at, name);
        self.publish(.{ .core = core, .kind = .plugged });
    }

    pub fn unplug(self: *Session, core: Core, at: Endpoint) anyerror!void {
        const hook = self.plugs orelse return Error.NoPlugs;
        try hook.plugFn(hook.context, at, null);
        self.publish(.{ .core = core, .kind = .unplugged });
    }

    pub fn waitSettled(self: *Session, timeout_ns: u64) anyerror!void {
        const display = self.display orelse return session_display.Error.NoDisplay;
        try display.waitSettled(timeout_ns);
    }

    pub fn frame(self: *Session, allocator: std.mem.Allocator) anyerror!Frame {
        const display = self.display orelse return session_display.Error.NoDisplay;
        const captured = try display.frame(allocator);
        self.publish(.{ .core = self.currentCore(), .kind = .lcd_frame, .payload = .{ .frame = .{ .width = captured.width, .height = captured.height, .generation = self.now() catch 0, .dirty = .{ .x = 0, .y = 0, .width = @intCast(@min(captured.width, std.math.maxInt(u16))), .height = @intCast(@min(captured.height, std.math.maxInt(u16))) } } } });
        return captured;
    }

    /// Load image bytes through the board-specific loader, then publish it.
    pub fn load(self: *Session, core: Core, image: []const u8) anyerror!void {
        try self.select(core);
        const loader = self.loader orelse return Error.NoLoader;
        try loader.loadFn(loader.context, core, image);
        const tree_address = if (elf.Image.init(image)) |parsed|
            symbols.addressOf(parsed, widget_tree.symbol)
        else |_|
            null;
        self.widget_tree_addresses[@intFromEnum(core)] = tree_address;
        self.publish(.{ .core = core, .kind = .loaded });
    }

    /// Read the latest visible widget snapshot published by ra8_widget.
    pub fn widgets(self: *Session, allocator: std.mem.Allocator, core: Core) anyerror![]Widget {
        try self.select(core);
        const address = self.widget_tree_addresses[@intFromEnum(core)] orelse return error.NoWidgetTree;
        return widget_tree.read(self.live.view(), address, allocator);
    }

    /// Tap the center of the uniquely named widget at virtual time `at_ns`.
    pub fn tapWidget(self: *Session, allocator: std.mem.Allocator, core: Core, at_ns: u64, name: []const u8) anyerror!void {
        const tree = try self.widgets(allocator, core);
        defer allocator.free(tree);

        var found: ?*const Widget = null;
        for (tree) |*widget| {
            if (!std.mem.eql(u8, widget.nameSlice(), name)) continue;
            if (found != null) return error.AmbiguousWidget;
            found = widget;
        }
        const widget = found orelse return error.WidgetNotFound;
        const rect = widget.rect;
        if (rect.w <= 0 or rect.h <= 0) return error.InvalidWidgetRect;
        const x = @as(i64, rect.x) + @divTrunc(rect.w, 2);
        const y = @as(i64, rect.y) + @divTrunc(rect.h, 2);
        if (x < 0 or x > std.math.maxInt(u16) or y < 0 or y > std.math.maxInt(u16)) return error.InvalidWidgetRect;
        try self.tap(core, at_ns, @intCast(x), @intCast(y));
    }

    /// Queue a panel-pixel tap for virtual board time `at_ns`.
    pub fn tap(self: *Session, core: Core, at_ns: u64, x: u16, y: u16) anyerror!void {
        try self.scheduleInput(core, at_ns, .{ .tap = .{ .x = x, .y = y } });
    }

    /// Queue a swipe; intermediate reports use the input script's cadence.
    pub fn swipe(self: *Session, core: Core, at_ns: u64, from: gt911.Contact, to: gt911.Contact, duration_ns: u64) anyerror!void {
        try self.scheduleInput(core, at_ns, .{ .swipe = .{ .from = from, .to = to, .duration_ns = duration_ns } });
    }

    /// Queue repeated contact reports for a virtual-time long press.
    pub fn longpress(self: *Session, core: Core, at_ns: u64, point: gt911.Contact, duration_ns: u64) anyerror!void {
        try self.scheduleInput(core, at_ns, .{ .longpress = .{ .point = point, .duration_ns = duration_ns } });
    }

    /// Queue an active-low board button press (released by the shared script).
    pub fn button(self: *Session, core: Core, at_ns: u64, which: Button) anyerror!void {
        try self.scheduleInput(core, at_ns, .{ .button = .{ .down = true, .button_id = which } });
    }

    fn advanceBoard(self: *Session, core: Core, instructions: u64) anyerror!void {
        const board = self.board_ticks[@intFromEnum(core)] orelse return;
        var left = instructions;
        while (left > 0) {
            const count: u32 = @intCast(@min(left, std.math.maxInt(u32)));
            try board.tick.run(board.guest, count);
            left -= count;
        }
    }

    fn scheduleInput(self: *Session, core: Core, at_ns: u64, event: input_script.Event) anyerror!void {
        try self.select(core);
        const script = self.input_script orelse return Error.NoInput;
        try script.schedule(.{ .at_ns = at_ns, .event = event });
        self.publish(.{ .core = core, .kind = .input_scheduled });
    }

    pub fn run(self: *Session, core: Core, command: Run) anyerror!Ended {
        try self.select(core);
        const cpu = self.live.core.cpu;
        const retired_before = cpu.retired;
        const ended = try self.live.go(command);
        try self.advanceBoard(core, cpu.retired - retired_before);
        self.publish(.{ .core = core, .kind = .stopped, .ended = ended });
        if (ended == .core) self.publish(.{ .core = core, .kind = .fault, .payload = .{ .fault = .{ .cause = @intFromEnum(std.meta.activeTag(ended.core)) } } });
        return ended;
    }

    pub fn step(self: *Session, core: Core) anyerror!Ended {
        return self.run(core, .step);
    }

    pub fn interrupt(self: *Session, core: Core) anyerror!stop_machine.Stop {
        try self.select(core);
        const stop = self.live.machine.interrupt();
        self.publish(.{ .core = core, .kind = .stopped, .ended = .{ .stop = stop } });
        return stop;
    }

    pub fn pause(self: *Session, core: Core) anyerror!void {
        try self.select(core);
        self.live.machine.requestHalt();
        self.publish(.{ .core = core, .kind = .paused });
    }

    /// Scale this core's run rate (1 is the default) and, with a speed hook,
    /// the pacer; the range is --speed's (session_speed.zig).
    pub fn setSpeed(self: *Session, core: Core, factor: f64) anyerror!void {
        const change = try session_speed.Change.of(factor, debug_session.limits.default_budget);
        try self.setRunBudget(core, change.budget);
        if (self.speed) |hook| try hook.setFn(hook.context, change.milli);
        self.publish(.{ .core = core, .kind = .speed_changed });
    }

    /// Set the deterministic instruction chunk a running frontend executes.
    pub fn setRunBudget(self: *Session, core: Core, instructions: u64) anyerror!void {
        if (instructions == 0) return error.InvalidSpeed;
        try self.select(core);
        self.live.budget = instructions;
    }

    pub fn register(self: *Session, core: Core, which: Register) anyerror!u32 {
        return (try self.view(core)).register(which);
    }

    pub fn setRegister(self: *Session, core: Core, which: Register, value: u32) anyerror!void {
        try (try self.view(core)).setRegister(which, value);
        self.publish(.{ .core = core, .kind = .register_written });
    }

    pub fn read(self: *Session, core: Core, address: u32, into: []u8) anyerror!void {
        try (try self.view(core)).read(address, into);
    }
    pub fn write(self: *Session, core: Core, address: u32, bytes: []const u8) anyerror!void {
        try (try self.view(core)).write(address, bytes);
        self.publish(.{ .core = core, .kind = .memory_written, .address = address });
    }
    pub fn setBreakpoint(self: *Session, core: Core, point: breakpoint.Break) anyerror!BreakId {
        try self.select(core);
        const id = try self.live.machine.addBreak(point);
        self.publish(.{ .core = core, .kind = .breakpoint_set, .address = point.address });
        return id;
    }

    pub fn setWatchpoint(self: *Session, core: Core, point: watch_table.Watch) anyerror!WatchId {
        try self.select(core);
        const id = try self.live.machine.addWatch(point);
        self.publish(.{ .core = core, .kind = .watchpoint_set, .address = point.first });
        return id;
    }

    pub fn clearBreakpoint(self: *Session, core: Core, id: BreakId) anyerror!void {
        try self.select(core);
        try self.live.machine.breaks.remove(id);
        self.publish(.{ .core = core, .kind = .breakpoint_cleared });
    }

    pub fn clearWatchpoint(self: *Session, core: Core, id: WatchId) anyerror!void {
        try self.select(core);
        try self.live.machine.watches.remove(id);
        self.publish(.{ .core = core, .kind = .watchpoint_cleared });
    }
    pub const RemovedPoint = enum { breakpoint, watchpoint };

    pub fn removePoint(self: *Session, core: Core, id: u32) anyerror!RemovedPoint {
        try self.select(core);
        self.live.machine.breaks.remove(id) catch |err| {
            if (err != error.NoSuchBreak) return err;
            self.live.machine.watches.remove(id) catch return error.NoSuchBreak;
            self.publish(.{ .core = core, .kind = .watchpoint_cleared });
            return .watchpoint;
        };
        self.publish(.{ .core = core, .kind = .breakpoint_cleared });
        return .breakpoint;
    }

    pub fn breakpointExists(self: *Session, core: Core, id: BreakId) anyerror!bool {
        try self.select(core);
        return self.live.machine.breaks.get(id) != null;
    }

    pub fn watchKind(self: *Session, core: Core, id: WatchId) anyerror!?watch_table.Kind {
        try self.select(core);
        const point = self.live.machine.watches.get(id) orelse return null;
        return point.kind;
    }

    pub fn hasCore(self: *const Session, core: Core) bool {
        return @intFromEnum(core) == self.live.index or self.live.other != null;
    }

    pub fn currentCore(self: *const Session) Core {
        return @enumFromInt(self.live.index);
    }

    pub fn switchTo(self: *Session, core: Core) anyerror!void {
        try self.select(core);
    }

    pub fn view(self: *Session, core: Core) anyerror!core_view.View {
        try self.select(core);
        return self.live.view();
    }

    pub fn machine(self: *Session, core: Core) anyerror!*stop_machine.Machine {
        try self.select(core);
        return self.live.machine;
    }

    pub fn itmPort(self: *Session, core: Core) anyerror!*itm.Itm {
        try self.select(core);
        return &self.live.machine.itm;
    }

    pub fn flushItm(self: *Session, core: Core, out: anytype, final: bool) anyerror!void {
        try self.select(core);
        try self.live.machine.itm.flush(out, final);
    }

    pub fn subscribe(self: *Session, listener: Listener) Error!usize {
        for (&self.listeners, 0..) |*slot, index| {
            if (slot.* != null) continue;
            slot.* = listener;
            return index;
        }
        return Error.TooManyListeners;
    }

    pub fn unsubscribe(self: *Session, id: usize) void {
        if (id < self.listeners.len) self.listeners[id] = null;
    }

    fn select(self: *Session, core: Core) anyerror!void {
        return self.live.switchTo(@intFromEnum(core));
    }

    /// Publish a board observation into bounded subscriber queues.
    fn publish(self: *Session, event: Event) void {
        var stamped = event;
        stamped.virtual_ns = self.now() catch 0;
        self.event_stream.publish(stamped);
        for (self.listeners) |slot| if (slot) |listener| listener.receive(listener.context, stamped);
    }
};
