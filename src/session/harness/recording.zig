//! Enable undo recording and the bounded reverse window on a loaded harness.
const Harness = @import("harness.zig").Harness;
const history_trail = @import("../history/trail.zig");
const window_box = @import("window.zig");

pub fn record(self: *Harness) !void {
    const state = self.state;
    const cpu0 = state.loading.cpu[0] orelse return error.CoreNotAttached;
    const cpu1 = state.loading.cpu[1] orelse return error.CoreNotAttached;
    if (state.cpu0.store == null) return error.StoreMissing;
    state.recording = history_trail.Recording.init(
        state.allocator,
        .{ &cpu0.slots, &cpu1.slots },
        &state.cpu0.store.?,
    );
    state.recording.?.arm();
}

pub fn openWindow(self: *Harness, bytes: usize) !void {
    const state = self.state;
    state.window = try window_box.Window.create(
        state.allocator,
        &state.session,
        &state.files,
        &state.cpu0.store.?,
        &state.memory,
        &state.cpu.slots,
        bytes,
    );
}
