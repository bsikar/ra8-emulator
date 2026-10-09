//! Text for the bkpt group: BKPT #imm8.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("bkpt ", .{});
    out.imm(instr.hw1 & 0xFF);
}
