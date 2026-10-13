//! Ordered gaps in a saved two-core round.
const std = @import("std");

pub const Phase = enum(u8) { cpu0, cpu1, board };
pub const Gap = enum(u8) { retired, polled };
pub const Position = struct {
    branch: u32 = 0,
    r: u64 = 0,
    phase: Phase = .cpu0,
    o: u32 = 0,
    gap: Gap = .retired,

    /// Branches are separate lines, so their positions are incomparable.
    pub fn order(a: Position, b: Position) ?std.math.Order {
        if (a.branch != b.branch) return null;
        inline for (.{ "r", "phase", "o", "gap" }) |name| {
            const left = @field(a, name);
            const right = @field(b, name);
            const result = if (@typeInfo(@TypeOf(left)) == .@"enum")
                std.math.order(@backingInt(left), @backingInt(right))
            else
                std.math.order(left, right);
            if (result != .eq) return result;
        }
        return .eq;
    }

    pub fn slots(self: Position, core: u1, base: [2]u64, lengths: [2]u32) u64 {
        const phase = @backingInt(self.phase);
        return base[core] + if (phase < core) @as(u64, 0) else if (phase == core) self.o else lengths[core];
    }
};
