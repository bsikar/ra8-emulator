//! Text for the sp_arith group: ADR, ADD Rd, SP, #imm, and ADD/SUB SP, #imm.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    switch (hw1 >> 11) {
        0b10100 => out.put("adr {s}, ", .{text.names[text.low(hw1, 8)]}),
        0b10101 => out.put("add {s}, sp, ", .{text.names[text.low(hw1, 8)]}),
        else => {
            out.put("{s} sp, ", .{if (hw1 & 0x80 != 0) "sub" else "add"});
            return out.imm((hw1 & 0x7F) << 2);
        },
    }
    out.imm((hw1 & 0xFF) << 2);
}
