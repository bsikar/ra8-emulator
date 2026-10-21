//! The seek engine's facts, gathered from one committed log (unit 17):
//! every checkpoint the log names and the furthest round its records
//! reach. The live cursor stays the caller's to supply; the log proves
//! the rest. One walk, no index: the per-seek cost is the log's length,
//! which the index contracts (units 22/23) replace when they land.

const std = @import("std");
const replay_mod = @import("replay.zig");
const seek_engine = @import("seek_engine.zig");

/// What one committed log proves for a seek.
pub const Facts = struct {
    /// Every checkpoint the log names, in log order.
    checkpoints: []seek_engine.Checkpoint,
    /// The furthest round any record's position names; zero when the
    /// log holds no positioned record.
    head_r: u64,
};

pub const Error = error{OutOfMemory} || replay_mod.Error;

/// Walks the committed bytes once and gathers the facts. The caller
/// frees the returned checkpoint list with the same allocator.
pub fn gather(gpa: std.mem.Allocator, bytes: []const u8) Error!Facts {
    var list: std.ArrayList(seek_engine.Checkpoint) = .empty;
    errdefer list.deinit(gpa);
    var head_r: u64 = 0;
    var ctx = Ctx{ .gpa = gpa, .list = &list, .head_r = &head_r };
    _ = try replay_mod.replay(bytes, &ctx, visit);
    return .{ .checkpoints = try list.toOwnedSlice(gpa), .head_r = head_r };
}

const Ctx = struct {
    gpa: std.mem.Allocator,
    list: *std.ArrayList(seek_engine.Checkpoint),
    head_r: *u64,
};

fn visit(ctx: *Ctx, entry: replay_mod.Entry) anyerror!void {
    switch (entry) {
        .root => {},
        .checkpoint => |hit| {
            try ctx.list.append(ctx.gpa, .{
                .position = hit.header.position,
                .id = hit.checkpoint.id,
                .object = hit.checkpoint.object,
            });
            note(ctx, hit.header.position.r);
        },
        .branch => |hit| note(ctx, hit.header.position.r),
        .intervention => |hit| note(ctx, hit.header.position.r),
        .boundary => |hit| note(ctx, hit.header.position.r),
    }
}

fn note(ctx: *Ctx, r: u64) void {
    if (r > ctx.head_r.*) ctx.head_r.* = r;
}
