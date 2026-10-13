//! Acquire cooperating roots in one resolved-path order.
const std = @import("std");
const base = @import("base.zig");
pub const Pair = struct {
    first: base.Gate,
    second: ?base.Gate = null,
    pub fn acquire(a: *const base.Base, b: ?*const base.Base) !Pair {
        const target = b orelse return .{ .first = try a.gate(.exclusive) };
        if (std.mem.eql(u8, a.path, target.path)) {
            if (a.role != target.role or (try a.dir.stat(a.io)).inode != (try target.dir.stat(target.io)).inode) return error.OutsideRoot;
            return .{ .first = try a.gate(.exclusive) };
        }
        const ordered = std.mem.order(u8, a.path, target.path) == .lt;
        var first = try (if (ordered) a else target).gate(.exclusive);
        errdefer first.release();
        return .{ .first = first, .second = try (if (ordered) target else a).gate(.exclusive) };
    }
    pub fn release(self: *Pair) void {
        if (self.second) |*held| held.release();
        self.first.release();
    }
};
