//! Text for the mov_wide group: MOVW and MOVT with their 16-bit immediate.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const mov_wide = @import("../ops/mov_wide.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const top = instr.hw1 & mov_wide.encodings.mask == mov_wide.encodings.movt;
    const rd: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    out.put("{s} {s}, ", .{ if (top) "movt" else "movw", text.names[rd] });
    out.imm(mov_wide.imm16(instr));
}
