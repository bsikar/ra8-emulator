//! The history's read-back: a committed log's records decoded in order,
//! so a replay pass can walk a session's recorded past without the
//! recorder. The twice-replay comparison and the positional filter sit
//! on this walk (RA8EMU-1196).
//!
//! The walk mirrors log.zig's scan on purpose: a whole frame that lies
//! about its length or fails its CRC is a hard error, a torn tail is
//! the only recoverable stop, and a frame whose kind nobody knows is
//! skipped unless the frozen table calls the kind mandatory.
const std = @import("std");
const format = @import("format.zig");
const log_mod = @import("log.zig");
const record = @import("record.zig");

pub const Error = error{UnknownMandatory} || format.Error || record.Error;

/// One decoded record, borrowing the log's bytes. The root's body is
/// root.zig's codec's to read; the walk hands it over raw.
pub const Entry = union(enum) {
    root: []const u8,
    branch: record.BranchRecord,
    checkpoint: record.CheckpointRecord,
    checkpoint_picture: record.CheckpointRecord,
    intervention: record.InterventionRecord,
    boundary: record.BoundaryRecord,
};

/// Walks a committed segment's frames in order, decoding each record and
/// handing it to `visit`, and stops at the first torn tail, reporting the
/// same recovery facts log.zig's scan reports.
pub fn replay(bytes: []const u8, context: anytype, comptime visit: fn (@TypeOf(context), Entry) anyerror!void) anyerror!log_mod.Recovery {
    var cursor: usize = 0;
    var frames: usize = 0;
    while (cursor < bytes.len) {
        const hit = format.decode(bytes[cursor..]) catch |err| switch (err) {
            error.Truncated => return .{ .complete_end = cursor, .frames = frames, .torn = true },
            else => return err,
        };
        const kind = hit.frame.kind;
        switch (kind & ~record.mandatory_bit) {
            @backingInt(record.Kind.root) => try visit(context, .{ .root = hit.frame.payload }),
            @backingInt(record.Kind.branch) => try visit(context, .{ .branch = try record.decodeBranch(hit.frame.payload) }),
            @backingInt(record.Kind.checkpoint) => try visit(context, .{ .checkpoint = try record.decodeCheckpoint(hit.frame.payload) }),
            @backingInt(record.Kind.checkpoint_picture) => try visit(context, .{ .checkpoint_picture = try record.decodeCheckpointPicture(hit.frame.payload) }),
            @backingInt(record.Kind.intervention) => try visit(context, .{ .intervention = try record.decodeIntervention(hit.frame.payload) }),
            @backingInt(record.Kind.boundary) => try visit(context, .{ .boundary = try record.decodeBoundary(hit.frame.payload) }),
            else => {
                if (record.mandatory(kind)) return Error.UnknownMandatory;
            },
        }
        frames += 1;
        cursor += hit.consumed;
    }
    return .{ .complete_end = bytes.len, .frames = frames, .torn = false };
}
