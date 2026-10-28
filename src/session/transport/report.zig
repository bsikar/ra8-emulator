//! The transport's report: the state, phase and progress of the job it
//! runs, read without running anything.
const command_mod = @import("command.zig");
const seek_mod = @import("seek.zig");
const transport = @import("transport.zig");

const Transport = transport.Transport;

/// The transport state now, without running anything.
pub fn report(self: *const Transport) command_mod.Report {
    var progress: command_mod.Progress = .{};
    var phase: command_mod.Phase = .halted;
    var state: ?command_mod.State = null;
    if (self.job) |*job| {
        progress.slices = job.slices;
        if (job.kind == .advance) {
            progress.target_ns = job.target_ns;
            progress.reached_ns = self.session.now() catch null;
        }
        if (job.kind == .seek) {
            progress.target_position = job.kind.seek.target;
            progress.eta_ns = seek_mod.eta(self, job);
        }
        phase = switch (job.kind) {
            .play => .playing,
            .cont => .continuing,
            .advance => .advancing,
            .step => .stepping,
            .seek => .seeking,
            .rcont => .reverse_continuing,
        };
        state = transport.jobState(job);
    }
    return .{
        .epoch = self.epoch,
        .phase = phase,
        .state = state,
        .position = if (self.session.grid) |grid| grid.at else null,
        .progress = progress,
    };
}
