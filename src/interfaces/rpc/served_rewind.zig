//! The served session's smooth-rewind sources: the frame cache and the
//! frame index the lookups read, the pinned checkpoint pictures read back
//! through the history bridge, the panel scan that decodes a segment, and
//! the restore of the nearest checkpoint a decode and a pause start from.
const std = @import("std");
const session = @import("ra8_session");
const harness = session.harness;
const history_bridge = @import("history_bridge.zig");
const nav_hooks = @import("session/nav_hooks.zig");
const served_setup = @import("served_setup.zig");

const Position = session.history_position.Position;

pub fn attach(self: *served_setup.Served, rewind: *session.smooth_rewind.SmoothRewindEngine) void {
    if (self.frames) |frames| rewind.decoder.bindCache(&frames.cache);
    if (self.nav) |nav| rewind.decoder.bindNav(nav);
    self.context.nav.status = .{ .context = self, .readFn = &readStatus };
    rewind.attachRestoreHook(.{ .context = self, .restoreFn = &restoreNearest });
    const state_file: *harness.files.StateFile = @ptrCast(@alignCast(self.owner.stateFiles().context));
    rewind.attachSources(.{
        .context = self,
        .refreshFn = &refresh,
        .objectFn = &object,
    }, session.harness_picture.source(state_file.files));
}

/// The pipeline's byte accounting: what the cache holds in RAM and on disk,
/// what the compositor's queue holds, and how many frames it keeps.
fn readStatus(context: *anyopaque) nav_hooks.FrameStatus {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    const frames = self.frames orelse return .{};
    return .{
        .ram_bytes = frames.cache.ramBytes(),
        .disk_bytes = frames.cache.diskBytes(),
        .queue_bytes = frames.queue.bytesUsed(),
        .frames = frames.cache.count(),
    };
}

fn bridgeOf(self: *served_setup.Served) !*history_bridge.Bridge {
    return if (self.bridge) |*b| b else error.NoHistory;
}

/// Puts the machine at the newest checkpoint at or before `target`.
fn restoreNearest(context: *anyopaque, target: Position) anyerror!void {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    const plane = self.owner.transport();
    const bridge = plane.history orelse return error.NoHistory;
    const facts = try bridge.facts(bridge.context);
    const live = self.owner.session();
    var best: ?@TypeOf(facts.checkpoints[0]) = null;
    for (facts.checkpoints) |c| {
        const behind = live.comparePositions(c.position, target) catch continue;
        if (behind == .gt) continue;
        if (best) |held| {
            const newer = live.comparePositions(c.position, held.position) catch continue;
            if (newer != .gt) continue;
        }
        best = c;
    }
    const chosen = best orelse return error.NoRestorePoint;
    try plane.restoreBase(.{ .checkpoint = .{ .id = chosen.id, .object = chosen.object, .position = chosen.position } });
}

/// Reads the committed log's picture records into the index.
fn refresh(context: *anyopaque, index: *session.history_checkpoint_picture.Index) anyerror!void {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    const plane = self.owner.transport();
    const bridge = plane.history orelse return error.NoHistory;
    try index.addFromLog(try bridge.logBytes.?(bridge.context));
}

fn object(context: *anyopaque, allocator: std.mem.Allocator, name: []const u8) anyerror![]u8 {
    const self: *served_setup.Served = @ptrCast(@alignCast(context));
    return history_bridge.Bridge.objectBytes(try bridgeOf(self), allocator, name);
}
