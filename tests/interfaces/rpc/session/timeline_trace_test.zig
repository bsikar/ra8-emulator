//! Host tests for the timeline model against a served both-cores run
//! (RA8EMU-840): the wire trace topic's events feed the model, the same
//! run's trace is recorded exactly as --trace-rtos-out records it, and
//! every recorded switch and ISR event lands as a slice edge on the right
//! core's lane at the same virtual time. Per-lane load agrees with the
//! tracer's own cpu_load within the RA8EMU-268 tolerance, and zooming down
//! to one slice keeps the hit test. The image is the Zig-built
//! threadx_dual pair (no C, no committed binary).
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");

const served = ra8.rpc.session.server;
const rpc = served.rpc_lib;
const proto = ra8.rpc.session.rpc;
const setup = ra8.rpc.served_setup;
const gui_app = @import("gui_app");
const timeline_model = gui_app.timeline_model;
const pane = gui_app.timeline_pane;
const rtos_load = timeline_model.rtos_load;

const Env = proto.Client.Env;

const image0 = test_paths.threadx_dual;
const image1 = test_paths.threadx_dual_cpu1;

/// One received trace event, exactly as the wire carried it.
const Got = struct {
    core: proto.Core,
    kind: proto.EventKind,
    virtual_ns: u64,
    thread: u32,
    exception: u16,
};

/// Both ends of one served connection, with buffers off the stack.
const Wire = struct {
    gpa: std.mem.Allocator,
    pipes: [2][]u8,
    rx: [2][]u8,
    tx: []u8,
    loop: rpc.Loopback = undefined,
    client: proto.Client = undefined,
    host: served.Host = undefined,
    got: std.ArrayListUnmanaged(Got) = .empty,

    fn init(gpa: std.mem.Allocator) !*Wire {
        const self = try gpa.create(Wire);
        self.* = .{ .gpa = gpa, .pipes = undefined, .rx = undefined, .tx = try gpa.alloc(u8, Env.max_frame) };
        for (&self.pipes) |*pipe| pipe.* = try gpa.alloc(u8, 2 * Env.max_frame);
        for (&self.rx) |*rx| rx.* = try gpa.alloc(u8, 2 * Env.max_frame);
        self.loop = rpc.Loopback.init(self.pipes[0], self.pipes[1]);
        return self;
    }

    fn deinit(self: *Wire) void {
        for (self.pipes ++ self.rx) |buffer| self.gpa.free(buffer);
        self.gpa.free(self.tx);
        self.got.deinit(self.gpa);
        self.gpa.destroy(self);
    }

    fn open(self: *Wire, context: *served.Context) !void {
        self.client = proto.Client.init(self.loop.a(), self.rx[0], proto.capabilities);
        self.host = served.Host.init(self.loop.b(), self.rx[1], context);
        try self.client.greet(self.tx);
        try std.testing.expectEqual(rpc.Step.greeted, try self.host.poll(self.tx));
        _ = (try self.client.poll(self.tx)).?;
    }

    fn call(self: *Wire, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
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
};

fn accepted(result: Env.Result) !void {
    switch (result) {
        .ok => {},
        .err => return error.Refused,
    }
}

/// The owner one wire event's time went to, in the model's terms.
fn ownerOf(got: Got) rtos_load.Owner {
    return switch (got.kind) {
        .rtos_switch => .{ .kind = .thread, .id = got.thread },
        .rtos_idle => .{ .kind = .idle },
        .isr_enter, .isr_leave => .{ .kind = .exception, .id = got.exception },
        else => unreachable,
    };
}

fn eventOf(got: Got) timeline_model.rtos_trace.Event {
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

/// The file one core's tracer wrote, read back the way --trace-rtos-out's
/// reader takes it.
fn recorded(gpa: std.mem.Allocator, io: std.Io, path: []const u8, core: usize, trace_file: []const u8) ![]const timeline_model.rtos_trace.Event {
    _ = trace_file;
    const file = ra8.session.rtos.hook.file;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    const name = try file.nameFor(path, @intCast(core), &name_buf);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(1 << 16));
    defer gpa.free(bytes);
    const into = try gpa.alloc(timeline_model.rtos_trace.Event, 256);
    defer gpa.free(into);
    const loaded = try file.read(bytes, into);
    try std.testing.expectEqual(@as(usize, 0), loaded.dropped);
    return try gpa.dupe(timeline_model.rtos_trace.Event, loaded.events);
}

test "the timeline model matches the recorded both-cores trace" {
    const gpa = std.testing.allocator;
    var opened: setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image0, null, null);
    defer opened.deinit();
    try opened.openSecond(image1);
    var wire = try Wire.init(gpa);
    defer wire.deinit();
    try wire.open(&opened.context);
    try accepted(try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .trace }));
    try accepted(try wire.call(proto.Subscription, .subscribe, .{ .core = .cpu1, .topic = .trace }));
    // Run both cores by instruction budget, one call at a time, so each
    // answer drains the feed and no tracer ring or queue drops anything.
    for (0..2) |_| {
        try accepted(try wire.call(proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 60_000 }));
        try accepted(try wire.call(proto.Run, .run, .{ .core = .cpu1, .mode = .cont, .budget = 60_000 }));
    }
    try std.testing.expect(wire.got.items.len > 0);

    // The tracers recorded the same events, and dropped none.
    const t0 = &opened.owner.state.tracer.?;
    const t1 = &opened.second.?.tracer.?;
    try std.testing.expectEqual(@as(usize, 0), t0.trace.dropped);
    try std.testing.expectEqual(@as(usize, 0), t1.trace.dropped);

    // The same run, recorded exactly as --trace-rtos-out records it.
    const file = ra8.session.rtos.hook.file;
    const path = "/tmp/ra8-timeline-840.txt";
    try file.save(std.testing.io, std.Io.Dir.cwd(), path, 0, &t0.trace);
    try file.save(std.testing.io, std.Io.Dir.cwd(), path, 1, &t1.trace);

    // Feed the wire events into the model, then close both cores' runs.
    var model = timeline_model.Model.init(gpa);
    defer model.deinit();
    var last_ns: u64 = 0;
    for (wire.got.items) |got| {
        try model.take(eventOf(got));
        last_ns = @max(last_ns, got.virtual_ns);
    }
    try model.finish(last_ns);
    const window = model.recorded() orelse return error.NoRecord;

    // Every core's recorded file matches that core's wire events, and
    // every one of them is a slice edge on the right core's lane.
    for (0..2) |core_index| {
        const core: u1 = @intCast(core_index);
        const got = try recorded(gpa, std.testing.io, path, core_index, path);
        defer gpa.free(got);
        var wire_count: usize = 0;
        for (wire.got.items) |one| {
            if ((one.core == .cpu0) == (core_index == 0)) wire_count += 1;
        }
        try std.testing.expectEqual(wire_count, got.len);
        var switches: usize = 0;
        var enters: usize = 0;
        var idles: usize = 0;
        for (got) |one| {
            switch (one.kind) {
                .switch_to => switches += 1,
                .idle => idles += 1,
                .enter => enters += 1,
                .leave => {},
            }
        }
        try std.testing.expect(switches > 0);
        try std.testing.expect(enters > 0);
        try std.testing.expect(idles > 0);
        for (wire.got.items) |one| {
            if ((one.core == .cpu0) != (core_index == 0)) continue;
            const lane = model.laneIndex(core, ownerOf(one).kind, ownerOf(one).id) orelse {
                return error.MissingLane;
            };
            var edge = false;
            for (model.slicesOf(lane)) |slice| {
                if (slice.start_ns == one.virtual_ns or slice.end_ns == one.virtual_ns) edge = true;
            }
            try std.testing.expect(edge);
        }
    }

    // Per-lane load agrees with the 269 load module fed the same
    // board-stamped events, within the RA8EMU-268 tolerance of one
    // percentage point. The tracer's own load is charged on the borrowed
    // fine clock (the traced core's retired instructions), so its shares
    // cover the core's execution rather than the board's virtual span;
    // the model is a timeline over that span, so the like-for-like oracle
    // is the same module on the same stamps.
    var oracle = timeline_model.rtos_load.Load{};
    for (wire.got.items) |got| oracle.feed(eventOf(got));
    oracle.finish(last_ns);
    for (0..2) |core_index| {
        const core: u1 = @intCast(core_index);
        for (oracle.rows(core)) |slot| {
            if (slot.owner.kind == .before) continue;
            const lane = model.laneIndex(core, slot.owner.kind, slot.owner.id) orelse return error.MissingLane;
            // Both charged the same board-stamped events, so the lane's
            // ticks match the slot's exactly.
            try std.testing.expectEqual(slot.ticks, model.laneTicks(lane, window.from, window.to));
        }
    }

    // Zoom the whole run down to one slice: a view so narrow it sits
    // inside one slice's span still hits that slice.
    var zoomed: ?usize = null;
    for (model.lanes.items, 0..) |*row, index| {
        for (row.slices.items) |slice| {
            if (slice.end_ns - slice.start_ns < 4) continue;
            const view = timeline_model.View{
                .start_ns = slice.start_ns + (slice.end_ns - slice.start_ns) / 4,
                .span_ns = (slice.end_ns - slice.start_ns) / 2,
                .width_px = 400,
            };
            const area = ra8.render.draw_list.Rect{ .x = 0, .y = 0, .w = 400, .h = pane.ruler_h + pane.header_h + 10 * pane.row_h };
            const x = pane.col_w + 100;
            const y = pane.header_h + @as(i32, @intCast(index)) * pane.row_h + 2;
            const hit = pane.hitAt(area, &model, view, x, y) orelse continue;
            try std.testing.expectEqual(slice.start_ns, hit.start_ns);
            zoomed = index;
            break;
        }
        if (zoomed != null) break;
    }
    try std.testing.expect(zoomed != null);
}
