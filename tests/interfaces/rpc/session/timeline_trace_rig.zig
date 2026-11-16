//! Shared wire rig and 1-by-1 sequence oracle for `timeline_trace_test.zig`.
const std = @import("std");
const ra8 = @import("ra8");

pub const served = ra8.rpc.session.server;
pub const rpc = served.rpc_lib;
pub const proto = ra8.rpc.session.rpc;
pub const setup = ra8.rpc.served_setup;
pub const rtos_trace = ra8.session.rtos.trace;

pub const Env = proto.Client.Env;

/// One received trace event, exactly as the wire carried it.
pub const Got = struct {
    core: proto.Core,
    kind: proto.EventKind,
    virtual_ns: u64,
    thread: u32,
    exception: u16,
};

pub const SequenceError = error{
    LengthMismatch,
    CoreMismatch,
    KindMismatch,
    NonMonotonicTime,
    TimeMismatch,
    ThreadMismatch,
    ExceptionMismatch,
};

pub const SequenceStats = struct {
    total: usize = 0,
    equal_pos: usize = 0,
    switches: usize = 0,
    idles: usize = 0,
    enters: usize = 0,
    leaves: usize = 0,
};

/// Both ends of one served connection, with buffers off the stack.
pub const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,
    got: std.ArrayListUnmanaged(Got) = .empty,

    pub fn init(gpa: std.mem.Allocator) !*Wire {
        const self = try gpa.create(Wire);
        self.* = .{ .gpa = gpa, .pipes = undefined, .rx = undefined, .tx = try gpa.alloc(u8, Env.max_frame) };
        for (&self.pipes) |*pipe| pipe.* = try gpa.alloc(u8, 2 * Env.max_frame);
        for (&self.rx) |*rx| rx.* = try gpa.alloc(u8, 2 * Env.max_frame);
        self.loop = rpc.Loopback.init(self.pipes[0], self.pipes[1]);
        return self;
    }

    pub fn deinit(self: *Wire) void {
        for (self.pipes ++ self.rx) |buffer| self.gpa.free(buffer);
        self.gpa.free(self.tx);
        self.got.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    pub fn open(self: *Wire, context: *served.Context) !void {
        self.client = proto.Client.init(self.loop.a(), self.rx[0], proto.capabilities);
        self.host = served.Host.init(self.loop.b(), self.rx[1], context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.host.poll(self.tx));
        _ = (try self.client.poll(self.tx)).?;
    }

    pub fn call(self: *Wire, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        try std.testing.expectEqual(rpc.Step.answered, try self.host.poll(self.tx));
        var result: ?Env.Result = null;
        while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
            .response => |response| result = response.result,
            .event => |event| {
                try std.testing.expectEqual(@backingInt(proto.Topic.trace), event.topic);
                const sent = try proto.decode(proto.TraceEvent, event.payload);
                try self.got.append(self.gpa, .{
                    .core = sent.core,
                    .kind = sent.kind,
                    .virtual_ns = sent.virtual_ns,
                    .thread = sent.thread,
                    .exception = sent.exception,
                });
            },
            .ready => return error.Unexpected,
        };
        return result orelse error.NoResponse;
    }

    pub fn callDecode(self: *Wire, comptime Args: type, comptime Reply: type, method: proto.Method, args: Args) !Reply {
        switch (try self.call(Args, method, args)) {
            .ok => |bytes| return try proto.decode(Reply, bytes),
            .err => return error.Refused,
        }
    }

    pub fn forCore(self: *const Wire, gpa: std.mem.Allocator, core: proto.Core) ![]Got {
        var list: std.ArrayListUnmanaged(Got) = .empty;
        errdefer list.deinit(gpa);
        for (self.got.items) |item| {
            if (item.core == core) try list.append(gpa, item);
        }
        return try list.toOwnedSlice(gpa);
    }
};

pub fn accepted(result: Env.Result) !void {
    switch (result) {
        .ok => {},
        .err => return error.Refused,
    }
}

pub fn eventOf(got: Got) rtos_trace.Event {
    return .{
        .when = got.virtual_ns,
        .core = if (got.core == .cpu0) 0 else 1,
        .kind = switch (got.kind) {
            .rtos_switch => .switch_to,
            .rtos_idle => .idle,
            .isr_enter => .enter,
            .isr_leave => .leave,
            else => unreachable,
        },
        .thread = got.thread,
        .exception = got.exception,
    };
}

/// One served session paired with one wire client; keep pinned on the stack.
pub const Rig = struct {
    served: setup.Served = undefined,
    wire: *Wire = undefined,

    pub fn open(self: *Rig, gpa: std.mem.Allocator, cpu0_path: []const u8, cpu1_path: ?[]const u8, state_dir: ?[]const u8) !void {
        try self.served.open(gpa, std.testing.io, cpu0_path, null, null);
        errdefer self.served.deinit();
        if (cpu1_path) |second| try self.served.openSecond(second);
        self.served.owner.setStateDir(state_dir);
        self.wire = try Wire.init(gpa);
        errdefer self.wire.deinit();
        try self.wire.open(&self.served.context);
    }

    pub fn deinit(self: *Rig) void {
        self.wire.deinit();
        self.served.deinit();
    }

    pub fn subscribeBoth(self: *Rig) !void {
        try accepted(try self.wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .trace }));
        try accepted(try self.wire.call(proto.Subscription, .subscribe, .{ .core = .cpu1, .topic = .trace }));
    }

    pub fn runBudget(self: *Rig, core: proto.Core, budget: u64) !void {
        try accepted(try self.wire.call(proto.Run, .run, .{ .core = core, .mode = .cont, .budget = budget }));
    }

    pub fn runSplit(self: *Rig, core: proto.Core, budgets: []const u64) !void {
        for (budgets) |budget| try self.runBudget(core, budget);
    }

    /// Save one core's trace to `dir` via `--trace-rtos-out`'s writer, read it
    /// back via its reader, and normalize cycle stamps through that core's publisher.
    pub fn recordedCore(self: *Rig, gpa: std.mem.Allocator, dir: std.Io.Dir, stem: []const u8, core_index: u1) ![]rtos_trace.Event {
        const tracer, const publisher = if (core_index == 0) blk: {
            const t = &(self.served.owner.state.tracer orelse return gpa.alloc(rtos_trace.Event, 0));
            break :blk .{ t, &self.served.owner.state.publisher };
        } else blk: {
            const sec = self.served.second orelse return gpa.alloc(rtos_trace.Event, 0);
            const t = &(sec.tracer orelse return gpa.alloc(rtos_trace.Event, 0));
            break :blk .{ t, &sec.publisher };
        };
        try std.testing.expectEqual(@as(usize, 0), tracer.trace.dropped);
        const file = ra8.session.rtos.hook.file;
        try file.save(std.testing.io, ra8.host.session_files.writerInDir(ra8.session.file_ops.Writer, &dir), stem, core_index, &tracer.trace);
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const name = try file.nameFor(stem, core_index, &name_buf);
        const bytes = try dir.readFileAlloc(std.testing.io, name, gpa, .limited(1 << 18));
        defer gpa.free(bytes);
        const into = try gpa.alloc(rtos_trace.Event, rtos_trace.limits.kept);
        defer gpa.free(into);
        const loaded = try file.read(bytes, into);
        try std.testing.expectEqual(@as(usize, 0), loaded.dropped);
        const out = try gpa.dupe(rtos_trace.Event, loaded.events);
        for (out) |*ev| ev.when = publisher.nsOf(ev.when);
        return out;
    }

    pub fn verifyBothCores(self: *Rig, gpa: std.mem.Allocator, dir: std.Io.Dir, stem: []const u8) ![2]SequenceStats {
        var out: [2]SequenceStats = undefined;
        for ([_]u1{ 0, 1 }) |idx| {
            const core: proto.Core = if (idx == 0) .cpu0 else .cpu1;
            const wire_core = try self.wire.forCore(gpa, core);
            defer gpa.free(wire_core);
            const file_core = try self.recordedCore(gpa, dir, stem, idx);
            defer gpa.free(file_core);
            out[idx] = try compareSequence(wire_core, file_core, core);
        }
        return out;
    }
};

/// Compare one core's wire stream against its normalized trace file 1-by-1.
pub fn compareSequence(wire_events: []const Got, file_events: []const rtos_trace.Event, want_core: proto.Core) SequenceError!SequenceStats {
    if (wire_events.len != file_events.len) return error.LengthMismatch;
    const want_u1: u1 = if (want_core == .cpu0) 0 else 1;
    var stats: SequenceStats = .{ .total = wire_events.len };
    for (wire_events, file_events, 0..) |w, f, i| {
        if (w.core != want_core or f.core != want_u1) return error.CoreMismatch;
        const norm = eventOf(w);
        if (norm.kind != f.kind) return error.KindMismatch;
        if (i > 0 and w.virtual_ns < wire_events[i - 1].virtual_ns) return error.NonMonotonicTime;
        if (w.virtual_ns != f.when) return error.TimeMismatch;
        if (w.thread != f.thread) return error.ThreadMismatch;
        if (w.exception != f.exception) return error.ExceptionMismatch;
        if (i > 0 and w.virtual_ns == wire_events[i - 1].virtual_ns) stats.equal_pos += 1;
        switch (f.kind) {
            .switch_to => stats.switches += 1,
            .idle => stats.idles += 1,
            .enter => stats.enters += 1,
            .leave => stats.leaves += 1,
        }
    }
    return stats;
}

/// Compare two wire event slices 1-by-1 for exact equality.
pub fn compareWireToWire(a: []const Got, b: []const Got) SequenceError!void {
    if (a.len != b.len) return error.LengthMismatch;
    for (a, b, 0..) |x, y, i| {
        if (x.core != y.core) return error.CoreMismatch;
        if (x.kind != y.kind) return error.KindMismatch;
        if (i > 0 and x.virtual_ns < a[i - 1].virtual_ns) return error.NonMonotonicTime;
        if (x.virtual_ns != y.virtual_ns) return error.TimeMismatch;
        if (x.thread != y.thread) return error.ThreadMismatch;
        if (x.exception != y.exception) return error.ExceptionMismatch;
    }
}
