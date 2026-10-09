//! Text for the blxns group: BLXNS Rm.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("blxns {s}", .{text.names[(instr.hw1 >> 3) & 0xF]});
}
