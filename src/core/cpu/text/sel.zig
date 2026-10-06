//! Text for the sel group: SEL Rd, Rn, Rm (no `.w`, as we print it).
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    out.regs3("sel", @intCast((instr.hw2 >> 8) & 0xF), @intCast(instr.hw1 & 0xF), @intCast(instr.hw2 & 0xF));
}
