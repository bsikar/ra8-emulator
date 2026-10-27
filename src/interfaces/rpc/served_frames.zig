//! The served session's passive frame pipeline: the tap, the compositor
//! worker and the frame cache, sized from the history's budgets and bound
//! to the board the served session owns.
const std = @import("std");
const harness = @import("ra8_session").harness;
const history_resources = @import("ra8_host").history.resources;
const history_storage = @import("ra8_host").history.storage;
const frame_tap = @import("ra8_session").history_frame_tap;
const frame_pipeline = @import("frame_pipeline.zig");
const history_bind = @import("history_bind.zig");
const served_setup = @import("served_setup.zig");

pub fn init(
    self: *served_setup.Served,
    allocator: std.mem.Allocator,
    io: std.Io,
    bind_inst: ?*history_bind.Bind,
    history_opts: ?served_setup.HistoryOpts,
) !void {
    const store = if (bind_inst) |b| history_storage.Store.from(&b.session) else null;
    const ram_val = try history_resources.ramBudget(if (history_opts) |o| o.ram_budget else null);
    const disk_val = if (bind_inst) |b| (if (b.disk) |d| d.cap else (if (history_opts) |o| o.budget orelse 0 else 0)) else (if (history_opts) |o| o.budget orelse 0 else 0);
    const state_file: *harness.files.StateFile = @ptrCast(@alignCast(self.owner.stateFiles().context));
    const grid_ptr = &state_file.files.edge.saved;
    const cpu_store = self.owner.guest().store;
    const clock = frame_tap.Clock.fromIo(&self.io);
    self.frames = try frame_pipeline.FramePipeline.init(
        allocator,
        io,
        self.owner.board(),
        cpu_store,
        grid_ptr,
        0,
        store,
        ram_val,
        disk_val,
        clock,
    );
    if (self.nav) |n| self.frames.?.bindNav(n);
    if (history_opts) |opts| if (opts.frame_hz) |hz| {
        self.frames.?.setIntervalNs(if (hz == 0) 0 else @divTrunc(std.time.ns_per_s, hz));
    };
}
