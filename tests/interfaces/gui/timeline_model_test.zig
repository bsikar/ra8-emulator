//! Tests for the timeline pane's model (RA8EMU-834): folding RTOS trace
//! events into per-core lanes, per-lane load against the RA8EMU-269 module
//! over the same window, view zoom and pan clamping, and hit tests at
//! slice edges.
const std = @import("std");
const gui_app = @import("gui_app");
const timeline_model = gui_app.timeline_model;
const rtos_load = timeline_model.rtos_load;
const rtos_trace = timeline_model.rtos_trace;

const allocator = std.testing.allocator;

/// The synthetic run: core 0 runs thread A, an ISR nesting another inside
/// it, thread B, then idles; core 1 runs thread C and idles.
const events = [_]rtos_trace.Event{
    .{ .when = 100, .core = 0, .kind = .switch_to, .thread = 0xA },
    .{ .when = 200, .core = 1, .kind = .switch_to, .thread = 0xC },
    .{ .when = 300, .core = 0, .kind = .enter, .exception = 15 },
    .{ .when = 350, .core = 0, .kind = .enter, .exception = 16 },
    .{ .when = 450, .core = 0, .kind = .leave, .exception = 16 },
    .{ .when = 500, .core = 0, .kind = .leave, .exception = 15 },
    .{ .when = 700, .core = 0, .kind = .switch_to, .thread = 0xB },
    .{ .when = 800, .core = 1, .kind = .idle },
    .{ .when = 900, .core = 0, .kind = .idle },
};

/// Each core's first event, so a window's covered time starts there.
const first_event = [_]u64{ 100, 200 };

fn recorded() !timeline_model.Model {
    var model = timeline_model.Model.init(allocator);
    errdefer model.deinit();
    for (events) |one| try model.take(one);
    try model.finish(1000);
    return model;
}

fn expectSlices(got: []const timeline_model.Slice, want: []const timeline_model.Slice) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (got, want) |one, expected| {
        try std.testing.expectEqual(expected.start_ns, one.start_ns);
        try std.testing.expectEqual(expected.end_ns, one.end_ns);
    }
}

test "the events fold into per-core lanes" {
    var model = try recorded();
    defer model.deinit();
    try std.testing.expectEqual(@as(usize, 7), model.laneCount());

    try expectSlices(model.slicesOf(model.laneIndex(0, .thread, 0xA).?), &.{
        .{ .start_ns = 100, .end_ns = 300 },
        .{ .start_ns = 500, .end_ns = 700 },
    });
    try expectSlices(model.slicesOf(model.laneIndex(0, .exception, 15).?), &.{
        .{ .start_ns = 300, .end_ns = 350 },
        .{ .start_ns = 450, .end_ns = 500 },
    });
    try expectSlices(model.slicesOf(model.laneIndex(0, .exception, 16).?), &.{
        .{ .start_ns = 350, .end_ns = 450 },
    });
    try expectSlices(model.slicesOf(model.laneIndex(0, .thread, 0xB).?), &.{
        .{ .start_ns = 700, .end_ns = 900 },
    });
    try expectSlices(model.slicesOf(model.laneIndex(0, .idle, 0).?), &.{
        .{ .start_ns = 900, .end_ns = 1000 },
    });
    try expectSlices(model.slicesOf(model.laneIndex(1, .thread, 0xC).?), &.{
        .{ .start_ns = 200, .end_ns = 800 },
    });
    try expectSlices(model.slicesOf(model.laneIndex(1, .idle, 0).?), &.{
        .{ .start_ns = 800, .end_ns = 1000 },
    });
    try std.testing.expectEqual(@as(?usize, null), model.laneIndex(1, .thread, 0xA));
}

/// One owner's ticks a 269 module charged over the test's window.
fn oracleTicks(oracle: *const rtos_load.Load, core: u1, kind: rtos_load.Kind, id: u32) u64 {
    for (oracle.rows(core)) |slot| {
        if (slot.owner.kind == kind and slot.owner.id == id) return slot.ticks;
    }
    return 0;
}

/// The model's per-lane load against a 269 module fed the same events,
/// plus each core's lanes covering the window's whole span together.
fn compareLoad(model: *const timeline_model.Model, from: u64, to: u64) !void {
    var oracle = rtos_load.Load{ .from = from, .to = to };
    for (events) |one| oracle.feed(one);
    oracle.finish(@max(to, 1000));

    for (0..timeline_model.limits.cores) |core_index| {
        var covered: u64 = 0;
        for (0..model.laneCount()) |index| {
            const lane = model.laneAt(index);
            if (lane.core != core_index) continue;
            const got = model.laneTicks(index, from, to);
            try std.testing.expectEqual(oracleTicks(&oracle, lane.core, lane.kind, lane.id), got);
            const share = model.lanePermille(index, from, to).?;
            try std.testing.expectEqual(got * 1000 / (to - from), share);
            covered += got;
        }
        const span = @min(to, 1000) - @max(from, first_event[core_index]);
        try std.testing.expectEqual(span, covered);
    }
}

test "per-lane load matches the 269 module over the same window" {
    var model = try recorded();
    defer model.deinit();
    try compareLoad(&model, 300, 1000);
    try compareLoad(&model, 0, 1000);
}

test "zoom and pan clamp to the record" {
    var model = try recorded();
    defer model.deinit();
    const rec = model.recorded().?;
    try std.testing.expectEqual(@as(u64, 100), rec.from);
    try std.testing.expectEqual(@as(u64, 1000), rec.to);

    const base = timeline_model.View{ .start_ns = 100, .span_ns = 900, .width_px = 900 };
    const close = base.zoom(500, 1, 2, rec);
    try std.testing.expectEqual(@as(u64, 300), close.start_ns);
    try std.testing.expectEqual(@as(u64, 450), close.span_ns);
    try std.testing.expectEqual(close.nsToX(500), base.nsToX(500));

    // Zoomed in, the anchor's ns still sits under the same pane x.
    try std.testing.expectEqual(@as(i32, 400), close.nsToX(500));

    // Zoom out past the record: the span clamps to what's recorded.
    const far = close.zoom(500, 10, 1, rec);
    try std.testing.expectEqual(rec.to - rec.from, far.span_ns);
    try std.testing.expectEqual(rec.from, far.start_ns);

    // Zoom in to the span floor.
    const tight = base.zoom(500, 1, 1000, rec);
    try std.testing.expectEqual(@as(u64, 1), tight.span_ns);
    try std.testing.expectEqual(@as(u64, 500), tight.start_ns);

    // Pan inside the record moves; past either end clamps.
    try std.testing.expectEqual(@as(u64, 500), close.pan(200, rec).start_ns);
    try std.testing.expectEqual(@as(u64, 550), close.pan(300, rec).start_ns);
    try std.testing.expectEqual(rec.from, close.pan(-1000, rec).start_ns);
}

test "the hit test reads slices at their edges" {
    var model = try recorded();
    defer model.deinit();
    const view = timeline_model.View{ .start_ns = 100, .span_ns = 900, .width_px = 900 };

    const thread_a = model.laneIndex(0, .thread, 0xA).?;
    try std.testing.expectEqual(@as(u64, 100), model.hit(thread_a, view, 100).?.start_ns);
    // The thread's own lane shows nothing while its ISR runs.
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), model.hit(thread_a, view, 300));

    // Lane 15: its slice's end is the nested ISR's time, and its restart
    // edge is inside.
    const outer = model.laneIndex(0, .exception, 15).?;
    try std.testing.expectEqual(@as(u64, 300), model.hit(outer, view, 249).?.start_ns);
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), model.hit(outer, view, 250));
    try std.testing.expectEqual(@as(u64, 450), model.hit(outer, view, 350).?.start_ns);
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), model.hit(outer, view, 400));

    // The nested ISR holds the middle of the outer's time.
    const nested = model.laneIndex(0, .exception, 16).?;
    try std.testing.expectEqual(@as(u64, 350), model.hit(nested, view, 250).?.start_ns);

    // A pane x clamps to the view, so its right edge still reads the
    // newest slice; before that slice starts there is nothing.
    const idle = model.laneIndex(0, .idle, 0).?;
    try std.testing.expectEqual(@as(?timeline_model.Slice, null), model.hit(idle, view, 799));
    try std.testing.expectEqual(@as(u64, 900), model.hit(idle, view, 899).?.start_ns);
}

test "the ring keeps the newest window when it fills" {
    var model = timeline_model.Model.init(allocator);
    defer model.deinit();
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        try model.take(.{ .when = i * 10, .core = 0, .kind = .switch_to, .thread = 0xA });
        try model.take(.{ .when = i * 10 + 5, .core = 0, .kind = .switch_to, .thread = 0xB });
    }
    try model.finish(3000);

    try std.testing.expectEqual(timeline_model.limits.slices, model.kept);
    const a = model.laneIndex(0, .thread, 0xA).?;
    const b = model.laneIndex(0, .thread, 0xB).?;
    try std.testing.expectEqual(@as(usize, 256), model.slicesOf(a).len);
    try std.testing.expectEqual(@as(usize, 256), model.slicesOf(b).len);
    try std.testing.expectEqual(@as(u64, 440), model.slicesOf(a)[0].start_ns);
    try std.testing.expectEqual(@as(u64, 445), model.slicesOf(b)[0].start_ns);
    try std.testing.expectEqual(@as(u64, 3000), model.recorded().?.to);
}

test "a stream event's rtos payload becomes a trace event" {
    const switching = timeline_model.streamToTrace(.{
        .core = .cpu1,
        .virtual_ns = 42,
        .kind = .rtos_switch,
        .payload = .{ .rtos = .{ .thread = 7 } },
    }).?;
    try std.testing.expectEqual(@as(u64, 42), switching.when);
    try std.testing.expectEqual(@as(u1, 1), switching.core);
    try std.testing.expectEqual(rtos_trace.Kind.switch_to, switching.kind);
    try std.testing.expectEqual(@as(u32, 7), switching.thread);

    const entering = timeline_model.streamToTrace(.{
        .core = .cpu0,
        .kind = .isr_enter,
        .payload = .{ .rtos = .{ .exception = 15 } },
    }).?;
    try std.testing.expectEqual(rtos_trace.Kind.enter, entering.kind);
    try std.testing.expectEqual(@as(u16, 15), entering.exception);

    // Non-RTOS kinds carry no trace event.
    try std.testing.expectEqual(@as(?rtos_trace.Event, null), timeline_model.streamToTrace(.{ .core = .cpu0, .kind = .lcd_frame }));
}
