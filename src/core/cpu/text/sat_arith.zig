//! Text for the sat_arith group: qadd, qdadd, qsub and qdsub, printed as
//! Rd, Rm, Rn (the operand order the Arm ARM uses).
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const sat = @import("../ops/sat_arith.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const kind: sat.Kind = @enumFromInt((instr.hw2 >> 4) & 0x3);
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    const rm: u4 = @intCast(instr.hw2 & 0xF);
    out.put("{s} {s}, {s}, {s}", .{ @tagName(kind), text.names[rd], text.names[rm], text.names[rn] });
}
