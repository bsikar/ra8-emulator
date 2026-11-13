//! Thin DAP dispatcher. Only wire lifecycle, handles and breakpoint ownership live here.
const std = @import("std");
const session = @import("ra8_session");
const p = @import("protocol.zig");
const inspection = @import("inspection.zig");
const Points = @import("points.zig").Points;
pub const Target = inspection.Target;
pub const Open = struct {
    context: *anyopaque,
    openFn: *const fn (*anyopaque, []const u8) anyerror!Target,
};
pub const Adapter = struct {
    allocator: std.mem.Allocator,
    target: ?Target = null,
    opener: ?Open = null,
    seq: u32 = 0,
    initialized: bool = false,
    connected: bool = false,
    configured: bool = false,
    stop_on_entry: bool = true,
    closed: bool = false,
    inspect: inspection.Inspection = .{},
    points: Points = .{},
    /// Pending wire operation, not a copy of the stop machine's mode or target.
    pending: ?struct { core: session.api.Core, first: ?session.api.Run } = null,

    pub fn deinit(self: *Adapter) void {
        self.points.deinit(self.allocator, if (self.target) |t| t.session else null);
    }

    /// Write one response for every valid request. Request failures are protocol errors.
    pub fn request(self: *Adapter, bytes: []const u8, out: *std.Io.Writer) !void {
        var arena: std.heap.ArenaAllocator = .init(self.allocator);
        defer arena.deinit();
        const parsed = try std.json.parseFromSlice(p.Value, arena.allocator(), bytes, .{ .allocate = .alloc_always, .max_value_len = 64 * 1024 });
        const req = parsed.value;
        if (!std.mem.eql(u8, try p.text(p.get(req, "type")), "request")) return error.InvalidRequest;
        if (try p.number(p.get(req, "seq")) == 0) return error.InvalidRequest;
        const command = try p.text(p.get(req, "command"));
        const args = p.get(req, "arguments");
        var body: std.Io.Writer.Allocating = .init(arena.allocator());
        defer body.deinit();
        self.dispatch(command, args, &body.writer) catch |err| {
            try p.response(arena.allocator(), out, try self.nextSeq(), req, "{}", @errorName(err));
            return;
        };
        try p.response(arena.allocator(), out, try self.nextSeq(), req, if (body.written().len == 0) "{}" else body.written(), null);
        if (equal(command, "launch") or equal(command, "attach")) try self.event(out, "initialized", @as(struct {}, .{}));
        if (equal(command, "configurationDone")) {
            if (self.stop_on_entry) try self.stopped(out, self.target.?.session.currentCore(), "entry") else try self.start(self.target.?.session.currentCore(), .cont);
        }
        if (equal(command, "pause")) try self.stopped(out, self.target.?.session.currentCore(), "pause");
        if (equal(command, "disconnect")) try self.event(out, "terminated", @as(struct {}, .{}));
    }

    fn dispatch(self: *Adapter, command: []const u8, args: p.Value, out: *std.Io.Writer) !void {
        if (equal(command, "initialize")) return self.initialize(args, out);
        if (!self.initialized or self.closed) return error.InvalidState;
        if (equal(command, "launch") or equal(command, "attach")) return self.connect(args, equal(command, "launch"));
        if (equal(command, "disconnect")) {
            if (self.target) |t| _ = try t.session.interrupt(t.session.currentCore());
            self.pending = null;
            self.closed = true;
            return;
        }
        if (!self.connected) return error.NotAttached;
        const target = self.target.?;
        if (equal(command, "pause")) {
            const core = try inspection.Inspection.thread(target, args);
            _ = try target.session.interrupt(core);
            self.pending = null;
            return;
        }
        if (self.pending != null) return error.notStopped;
        if (equal(command, "configurationDone")) {
            if (self.configured) return error.InvalidState;
            self.configured = true;
            return;
        }
        if (equal(command, "setExceptionBreakpoints")) {
            if ((try p.list(p.get(args, "filters"))).len != 0) return error.UnsupportedExceptionFilter;
            return out.writeAll("{\"breakpoints\":[]}");
        }
        if (equal(command, "threads")) {
            try out.writeAll("{\"threads\":[{\"id\":1,\"name\":\"CPU0\"}");
            if (target.session.hasCore(.cpu1)) try out.writeAll(",{\"id\":2,\"name\":\"CPU1\"}");
            return out.writeAll("]}");
        }
        if (equal(command, "setBreakpoints") or equal(command, "setInstructionBreakpoints")) {
            return self.points.replace(self.allocator, target.session, target.images[@backingInt(target.session.currentCore())], args, equal(command, "setInstructionBreakpoints"), out, self.inspect.lines_start_at_one);
        }
        if (equal(command, "stackTrace")) return self.inspect.stackTrace(target, args, out);
        if (equal(command, "scopes")) return self.inspect.scopes(target, args, out);
        if (equal(command, "variables")) return self.inspect.variables(target, args, out);
        const run: session.api.Run = if (equal(command, "continue")) .cont else if (equal(command, "stepIn")) .step else if (equal(command, "next")) .next else if (equal(command, "stepOut")) .finish else return error.UnsupportedRequest;
        if (!self.configured) return error.NotConfigured;
        const core = try inspection.Inspection.thread(target, args);
        const granularity = p.get(args, "granularity");
        if (granularity != .null and !equal(try p.text(granularity), "instruction")) return error.UnsupportedGranularity;
        try self.start(core, run);
        if (run == .cont) try out.writeAll("{\"allThreadsContinued\":true}");
    }

    fn initialize(self: *Adapter, args: p.Value, out: *std.Io.Writer) !void {
        if (self.initialized) return error.InvalidState;
        const format = p.get(args, "pathFormat");
        if (format != .null and !equal(try p.text(format), "path")) return error.UnsupportedPathFormat;
        self.inspect.lines_start_at_one = try boolean(args, "linesStartAt1", true);
        self.inspect.columns_start_at_one = try boolean(args, "columnsStartAt1", true);
        try p.quote(out, .{ .supportsConfigurationDoneRequest = true, .supportsInstructionBreakpoints = true, .supportsSteppingGranularity = true, .exceptionBreakpointFilters = @as([]const struct {}, &.{}) });
        self.initialized = true;
    }

    fn connect(self: *Adapter, args: p.Value, launch: bool) !void {
        if (self.connected) return error.InvalidState;
        if (try boolean(args, "noDebug", false)) return error.UnsupportedRequest;
        const stop = try boolean(args, "stopOnEntry", true);
        const program = p.get(args, "program");
        if (launch and program != .null) {
            const opener = self.opener orelse return error.NoLoader;
            self.target = try opener.openFn(opener.context, try p.text(program));
        }
        const target = self.target orelse return error.NoTarget;
        self.stop_on_entry = stop;
        _ = try target.session.interrupt(target.session.currentCore());
        try self.inspect.invalidate();
        self.connected = true;
    }

    fn start(self: *Adapter, core: session.api.Core, run: session.api.Run) !void {
        const live = self.target.?.session;
        if (live.window_driver != null) return error.UnsupportedHistory;
        try live.switchTo(core);
        try self.inspect.invalidate();
        self.pending = .{ .core = core, .first = run };
    }

    /// One bounded Session slice. The host checks input between calls, including partial frames.
    pub fn pump(self: *Adapter, out: *std.Io.Writer) !void {
        const job = self.pending orelse return;
        const live = self.target.?.session;
        try live.switchTo(job.core);
        const prior = live.live.budget;
        defer live.setRunBudget(job.core, prior) catch {};
        try live.setRunBudget(job.core, 20_000);
        const ended = if (job.first) |cmd| try live.run(job.core, cmd) else try live.continueRun(job.core);
        self.pending.?.first = null;
        if (ended == .count or (ended == .core and ended.core == .count)) return;
        self.pending = null;
        const core: session.api.Core = @fromBackingInt(@intCast(live.live.ended_index));
        const reason: []const u8 = switch (ended) {
            .stop => |stop| switch (stop) {
                .stepped => "step",
                .breakpoint, .unit_break => "breakpoint",
                .watchpoint, .unit_watch => "data breakpoint",
                .halt_requested => "pause",
                else => "exception",
            },
            else => "exception",
        };
        try self.stopped(out, core, reason);
    }

    fn stopped(self: *Adapter, out: *std.Io.Writer, core: session.api.Core, reason: []const u8) !void {
        try self.event(out, "stopped", .{ .reason = reason, .threadId = @as(u32, @backingInt(core)) + 1, .allThreadsStopped = true });
    }
    fn nextSeq(self: *Adapter) !u32 {
        self.seq = try std.math.add(u32, self.seq, 1);
        return self.seq;
    }
    fn event(self: *Adapter, out: *std.Io.Writer, name: []const u8, body: anytype) !void {
        try p.event(self.allocator, out, try self.nextSeq(), name, body);
    }
};

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn boolean(args: p.Value, key: []const u8, fallback: bool) !bool {
    const value = p.get(args, key);
    return if (value == .null) fallback else if (value == .bool) value.bool else error.InvalidArguments;
}
