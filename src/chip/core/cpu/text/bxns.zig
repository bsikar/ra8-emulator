//! Text for the bxns group: BXNS Rm.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("bxns {s}", .{text.names[(instr.hw1 >> 3) & 0xF]});
}
