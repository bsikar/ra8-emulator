//! Text for the divide group: sdiv and udiv Rd, Rn, Rm. These have no
//! 16-bit forms, so we print no .w.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const divide = @import("../ops/divide.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = divide.fields(instr);
    const name = if (instr.hw1 & divide.encodings.hw1_mask == divide.encodings.sdiv) "sdiv" else "udiv";
    out.put("{s} {s}, {s}, {s}", .{ name, text.names[f.rd], text.names[f.rn], text.names[f.rm] });
}
