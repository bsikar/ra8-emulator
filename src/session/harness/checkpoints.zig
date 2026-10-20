//! The harness's checkpoint arming (RA8EMU-1196): the closed-round
//! controller bound to the run's own save stream, fed by the
//! application's host storage and object space.
const std = @import("std");
const history_checkpoint = @import("../history/checkpoint.zig");
const history_recorder = @import("../history/recorder.zig");
const session_state = @import("../board/state.zig");
const scheduler = @import("ra8_chip").core.scheduler;
const zig_session = @import("../zig/session.zig");

/// The armed pair in one heap-stable box: the recorder owns the staging,
/// the controller owns the policy, and the boundary's hook points here,
/// so arming survives `wire`'s return.
pub const Armed = struct {
    recorder: history_recorder.Recorder,
    checkpoints: history_checkpoint.Checkpoint,
};

/// Arms the closed-round checkpoints on a session whose application bound
/// both a log storage and an object space. A second core refuses through
/// the session's own arming (RA8EMU-768).
pub fn arm(
    allocator: std.mem.Allocator,
    session: *zig_session.ZigSession,
    files: *session_state.Files,
    saved: *const scheduler.State,
    storage: history_recorder.Storage,
    objects: history_recorder.Objects,
    disk: ?history_recorder.Budget,
    checkpoint_cap: u64,
    every: u32,
) !*Armed {
    const armed = try allocator.create(Armed);
    errdefer allocator.destroy(armed);
    armed.recorder = try history_recorder.Recorder.init(allocator, storage, .{});
    errdefer armed.recorder.deinit();
    armed.recorder.objects = objects;
    armed.recorder.disk = disk;
    armed.checkpoints = .{
        .context = files,
        .saveFn = saveMachine,
        .recorder = &armed.recorder,
        .saved = saved,
        .every = every,
        .object_cap = checkpoint_cap,
    };
    try session.armCheckpoints(&armed.checkpoints);
    return armed;
}

/// Releases an armed pair: the recorder's staging goes and the box goes;
/// the application's storage and object space outlive both.
pub fn disarm(allocator: std.mem.Allocator, armed: *Armed) void {
    armed.recorder.deinit();
    allocator.destroy(armed);
}

/// The whole machine's save stream: the bytes a state file carries. A
/// checkpoint's object is the run file a restore reads back.
fn saveMachine(context: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    const self: *session_state.Files = @ptrCast(@alignCast(context));
    try self.writeTo(writer);
}
