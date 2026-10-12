//! Feeds the timeline model from the session's trace events (RA8EMU-838):
//! the wire's RTOS and ISR events, decoded and handed to the model in
//! board-time order. The shell arms the topic once its link is up.

const session_link = @import("session_link.zig");
const proto = @import("ra8_rpc").session.rpc;
const timeline_model = @import("timeline_model.zig");

/// Subscribe to the trace topic once the link is up. A server without
/// rtos tracing refuses it; the pane then keeps its waiting note.
pub fn arm(link: *session_link.Link, armed: *bool) void {
    if (armed.* or link.state != .connected) return;
    _ = link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .trace }) catch return;
    armed.* = true;
}

/// Take one pump arrival into the model; everything but a trace event
/// is ignored.
pub fn take(model: *timeline_model.Model, arrival: session_link.Arrival) !void {
    const event = switch (arrival) {
        .event => |ev| ev,
        .response => return,
    };
    if (event.topic != @backingInt(proto.Topic.trace)) return;
    const trace = proto.decode(proto.TraceEvent, event.payload) catch return;
    const one = fromWire(trace) orelse return;
    try model.take(one);
}

/// The wire event's session-model twin; null for a kind the trace topic
/// never carries.
pub fn fromWire(trace: proto.TraceEvent) ?timeline_model.rtos_trace.Event {
    const kind: timeline_model.rtos_trace.Kind = switch (trace.kind) {
        .rtos_switch => .switch_to,
        .rtos_idle => .idle,
        .isr_enter => .enter,
        .isr_leave => .leave,
        else => return null,
    };
    return .{
        .when = trace.virtual_ns,
        .core = @intCast(@backingInt(trace.core)),
        .kind = kind,
        .thread = trace.thread,
        .exception = trace.exception,
    };
}
