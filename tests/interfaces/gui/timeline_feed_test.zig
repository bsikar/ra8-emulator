//! Host tests for the timeline feed's wire mapping (RA8EMU-838): the
//! trace topic's RTOS and ISR events map onto the session-model twins
//! with their time, core, thread and exception, a foreign kind comes
//! back null, and mapped events land in a model as slices.

const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const feed = gui_app.timeline_feed;
const timeline_model = gui_app.timeline_model;
const proto = ra8.rpc.session.rpc;

test "fromWire maps the trace topic's four kinds" {
    const switch_event = feed.fromWire(.{ .core = .cpu0, .kind = .rtos_switch, .virtual_ns = 100, .thread = 0x2000_0010, .exception = 0, .name = "main" });
    try std.testing.expectEqual(timeline_model.rtos_trace.Kind.switch_to, switch_event.?.kind);
    try std.testing.expectEqual(@as(u64, 100), switch_event.?.when);
    try std.testing.expectEqual(@as(u1, 0), switch_event.?.core);
    try std.testing.expectEqual(@as(u32, 0x2000_0010), switch_event.?.thread);

    const idle = feed.fromWire(.{ .core = .cpu1, .kind = .rtos_idle, .virtual_ns = 200, .thread = 0, .exception = 0, .name = "" });
    try std.testing.expectEqual(timeline_model.rtos_trace.Kind.idle, idle.?.kind);
    try std.testing.expectEqual(@as(u1, 1), idle.?.core);

    const enter = feed.fromWire(.{ .core = .cpu0, .kind = .isr_enter, .virtual_ns = 300, .thread = 0, .exception = 15, .name = "" });
    try std.testing.expectEqual(timeline_model.rtos_trace.Kind.enter, enter.?.kind);
    try std.testing.expectEqual(@as(u16, 15), enter.?.exception);

    const leave = feed.fromWire(.{ .core = .cpu0, .kind = .isr_leave, .virtual_ns = 400, .thread = 0, .exception = 15, .name = "" });
    try std.testing.expectEqual(timeline_model.rtos_trace.Kind.leave, leave.?.kind);
}

test "fromWire comes back null for a kind the trace topic never carries" {
    try std.testing.expectEqual(@as(?timeline_model.rtos_trace.Event, null), feed.fromWire(.{ .core = .cpu0, .kind = .loaded, .virtual_ns = 0, .thread = 0, .exception = 0, .name = "" }));
}

test "mapped events land in a model as slices" {
    var model = timeline_model.Model.init(std.testing.allocator);
    defer model.deinit();
    try model.take(feed.fromWire(.{ .core = .cpu0, .kind = .rtos_switch, .virtual_ns = 100, .thread = 0x10, .exception = 0, .name = "main" }).?);
    try model.take(feed.fromWire(.{ .core = .cpu0, .kind = .isr_enter, .virtual_ns = 150, .thread = 0, .exception = 15, .name = "" }).?);
    try model.take(feed.fromWire(.{ .core = .cpu0, .kind = .isr_leave, .virtual_ns = 200, .thread = 0, .exception = 15, .name = "" }).?);
    try model.finish(300);
    const window = model.recorded().?;
    try std.testing.expectEqual(@as(u64, 100), window.from);
    const lanes = model.laneCount();
    try std.testing.expect(lanes >= 2);
    var slices: usize = 0;
    for (0..lanes) |index| slices += model.slicesOf(index).len;
    try std.testing.expect(slices >= 3);
}
