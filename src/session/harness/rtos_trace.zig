//! The harness's ThreadX tracing: the tracer in front of CPU0 that
//! publishes thread switches and exception entry and return.
const harness = @import("harness.zig");
const rtos_hook = @import("../step_hook.zig").rtos.hook;

const Harness = harness.Harness;

/// Publish CPU0's ThreadX switches and exception entry and return on the
/// session's event stream (RA8EMU-346): the tracer sits in front of the
/// core, drained at each chunk boundary; stamps are CPU0's retired
/// instructions, one cycle each. False with no ThreadX; call once.
pub fn traceRtos(self: *Harness) bool {
    const state = self.state;
    state.tracer = rtos_hook.resolve(state.image, .{}) orelse return false;
    const tracer = &state.tracer.?;
    tracer.now = &state.board.time.base.retired;
    tracer.trace.fine = &state.cpu.retired;
    tracer.exceptions = rtos_hook.isr.Watcher.start(&state.pending.model);
    state.listener = .{ .tracer = tracer };
    state.cpu.bus = state.listener.onBus(state.cpu.bus);
    if (state.cpu.source) |inner| state.cpu.source = state.listener.onSource(inner);
    state.publisher = .{ .trace = &tracer.trace, .stream = &state.session.event_stream, .inner = state.session.live.boundary, .time = &state.board.time.base };
    state.session.live.boundary = state.publisher.hook();
    return true;
}

/// Hands every thread switch and exception entry and return the tracer
/// sees to `observer`, as it happens. False when tracing is off.
pub fn observeRtos(self: *Harness, observer: ?rtos_hook.trace_events.Observer) bool {
    const tracer = if (self.state.tracer) |*found| found else return false;
    tracer.trace.observer = observer;
    return true;
}

/// Turn RTOS tracing on unless it already is; false without ThreadX.
pub fn traceIfRtos(self: *Harness) bool {
    if (self.state.tracer != null) return true;
    return self.traceRtos();
}
