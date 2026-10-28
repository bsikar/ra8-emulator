//! Drives a served session's prefetch pool from the transport: every
//! command cancels what the pool has queued or running, and a planned seek
//! asks for the checkpoints the cursor is most likely to be moved to next,
//! the one just behind the seek's base and the one just past its target.
//! The base itself is not asked for: the seek restores it at once.
const std = @import("std");
const session_api = @import("ra8_session").api;
const transport = @import("ra8_session").transport;
const seek_engine = @import("ra8_session").history_seek_engine;
const prefetch = @import("ra8_session").history_prefetch;
const ObjectId = @import("ra8_session").history_object_id.ObjectId;
const pool_mod = @import("prefetch_pool.zig");

pub const Hook = struct {
    pool: *pool_mod.Pool,
    session: *session_api.Session,

    pub fn hook(self: *Hook) transport.Hook {
        return .{ .context = self, .commandFn = &onCommand, .plannedFn = &onPlanned };
    }

    fn onCommand(context: *anyopaque) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        self.pool.cancel(self.session);
    }

    fn onPlanned(context: *anyopaque, plan: seek_engine.Plan, facts: seek_engine.Facts) void {
        const self: *Hook = @ptrCast(@alignCast(context));
        const base_r: u64 = switch (plan.base) {
            .checkpoint => |c| c.position.r,
            else => plan.target.r,
        };
        var behind: ?seek_engine.Checkpoint = null;
        var ahead: ?seek_engine.Checkpoint = null;
        for (facts.checkpoints) |c| {
            if (c.position.branch != plan.target.branch) continue;
            if (c.position.r < base_r) {
                if (behind == null or c.position.r > behind.?.position.r) behind = c;
            } else if (c.position.r > plan.target.r) {
                if (ahead == null or c.position.r < ahead.?.position.r) ahead = c;
            }
        }
        for ([_]?seek_engine.Checkpoint{ behind, ahead }) |maybe| {
            const c = maybe orelse continue;
            const req: prefetch.Request = .{ .id = c.id, .object = ObjectId{ .bytes = c.object } };
            self.pool.request(self.session, req) catch {};
        }
    }
};
