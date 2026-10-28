//! Which objects the committed log names: the frame walk the host's
//! orphan sweep bridges to, so the host can reclaim object files no
//! record references. The session defines the walk; the applications
//! wire it into the host prune, the same callback shape the recorder's
//! bind uses.

const std = @import("std");
const format = @import("format.zig");
const log = @import("log.zig");
const record = @import("record.zig");
const touched_pages = @import("touched_pages.zig");
const manifest = @import("manifest.zig");

/// One object name: the lowercase hex of a checkpoint record's 128-bit
/// truncated SHA-256, the same name the object space files carry.
pub const Name = [32]u8;

/// Walks one committed segment's frames and reports the object name of
/// every checkpoint record and of every checkpoint picture record: both
/// are committed objects the orphan sweep must keep. The walk stops at a torn tail the way the
/// recovery scan does, so uncommitted frames name nothing. A frame the
/// table calls mandatory but the reader cannot make sense of is a hard
/// error, and the walk stops before it.
pub fn scanCheckpointObjects(bytes: []const u8, context: anytype, comptime visit: fn (@TypeOf(context), Name) void) format.Error!void {
    return scan(bytes, context, visit, true);
}

/// The same walk narrowed to the checkpoint picture records: the names of
/// the pictures quota relief must never evict.
pub fn scanPictureObjects(bytes: []const u8, context: anytype, comptime visit: fn (@TypeOf(context), Name) void) format.Error!void {
    return scan(bytes, context, visit, false);
}

fn scan(bytes: []const u8, context: anytype, comptime visit: fn (@TypeOf(context), Name) void, comptime machines: bool) format.Error!void {
    const Walker = struct {
        segment: []const u8,
        ctx: @TypeOf(context),
        visitor: *const fn (@TypeOf(context), Name) void,

        fn see(self: *@This(), boundary: log.Boundary) void {
            const kind = boundary.kind & 0x7FFF;
            const picture = kind == @backingInt(record.Kind.checkpoint_picture);
            if (!picture and !(machines and kind == @backingInt(record.Kind.checkpoint))) return;
            const payload = self.segment[boundary.offset + format.header_len .. boundary.offset + boundary.consumed];
            // A checkpoint body ends with the 128-bit truncated digest;
            // anything shorter cannot name an object.
            if (payload.len < 20) return;
            var name: Name = undefined;
            const obj_bytes = payload[payload.len - 16 ..];
            for (obj_bytes, 0..) |byte, i| {
                _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
            }
            self.visitor(self.ctx, name);
            if (!picture and machines) {
                self.visitor(self.ctx, touched_pages.objectName(obj_bytes[0..16].*));
                self.visitor(self.ctx, manifest.objectName(obj_bytes[0..16].*));
            }
        }
    };
    var walker = Walker{ .segment = bytes, .ctx = context, .visitor = visit };
    _ = try log.scan(bytes, &walker, Walker.see);
}
