//! Text for the cps group: CPSIE or CPSID with the a, i and f letters it
//! names.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

const letters = [3]struct { bit: u16, name: []const u8 }{
    .{ .bit = 0x4, .name = "a" },
    .{ .bit = 0x2, .name = "i" },
    .{ .bit = 0x1, .name = "f" },
};

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("{s} ", .{if (instr.hw1 & 0x10 != 0) "cpsid" else "cpsie"});
    for (letters) |letter| {
        if (instr.hw1 & letter.bit != 0) out.put("{s}", .{letter.name});
    }
}
