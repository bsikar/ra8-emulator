//! A frozen board-time interval. Sleep consumes time without consuming slots.
pub const Stretch = struct {
    carry: u32 = 0,
    full: u32 = 0,
    dirty: bool = false,

    pub fn open(self: *Stretch, size: u32) void {
        if (self.full != 0) return;
        self.full = @max(size, 1);
    }

    pub fn left(self: Stretch) u32 {
        return self.full - self.carry;
    }

    pub fn nowAfter(self: Stretch, closed: u64) u64 {
        return closed +| self.carry;
    }
};

/// Root parameters and board edges alone select the next interval.
pub fn width(normal: u32, edges: []const u64, extend: bool) u32 {
    var nearest: u64 = 0;
    for (edges) |edge| {
        if (edge != 0 and (nearest == 0 or edge < nearest)) nearest = edge;
    }
    const base = @max(normal, 1);
    if (nearest == 0 or (!extend and nearest >= base)) return base;
    return @intCast(@min(nearest, 0xffffffff));
}
