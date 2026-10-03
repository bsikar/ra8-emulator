//! The decoder: asks each group in src/core/cpu/ops/table.zig in turn and
//! returns the first one that recognises the encoding.
const op = @import("op.zig");
const table = @import("ops/table.zig");
const Instr = @import("instr.zig").Instr;

pub const Hit = struct {
    /// The class the instruction was decoded under.
    group: []const u8,
    exec: op.Exec,
    /// Whether Unicorn can be the lockstep oracle for it; see `op.Group`.
    oracle: bool,
};

pub fn decode(instr: Instr) ?Hit {
    for (table.groups) |group| {
        if (group.decode(instr)) |exec| return .{ .group = group.name, .exec = exec, .oracle = group.oracle };
    }
    return null;
}

/// The decoded-instruction cache in front of `decode` (RA8EMU-317).
pub const cache = @import("decode_cache.zig");

/// The disassembler built on this table (RA8EMU-17).
pub const text = @import("text/all.zig");
