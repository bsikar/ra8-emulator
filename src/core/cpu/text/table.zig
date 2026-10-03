//! The printer table: which decode group each printer covers, by the group's
//! name in src/core/cpu/ops/table.zig. A group with no entry here has no text
//! yet, and `disasm.one` returns null for it.
const Instr = @import("../instr.zig").Instr;
const Text = @import("text.zig").Text;
const std = @import("std");

pub const Print = *const fn (instr: Instr, out: *Text) void;

pub const Entry = struct {
    group: []const u8,
    print: Print,
};

pub const entries = [_]Entry{
    .{ .group = "shift_imm", .print = @import("shift_imm.zig").print },
    .{ .group = "add_sub", .print = @import("add_sub.zig").print },
    .{ .group = "dp_reg", .print = @import("dp_reg.zig").print },
    .{ .group = "special_data", .print = @import("special_data.zig").print },
    .{ .group = "extend", .print = @import("extend.zig").print },
    .{ .group = "reverse", .print = @import("reverse.zig").print },
};

pub fn find(group: []const u8) ?Print {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.group, group)) return entry.print;
    }
    return null;
}
