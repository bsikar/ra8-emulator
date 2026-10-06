//! Text for the udf group: UDF #imm8 (T1) and UDF.W #imm16 (T2), whose
//! immediate is hw1[3:0]:hw2[11:0]. We spell UDF #0xfe (0xDEFE) as
//! its LLVM alias `trap`, so this does too.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

/// UDF #0xfe, which we print as `trap`.
pub const trap: u16 = 0xDEFE;

pub fn print(instr: Instr, out: *text.Text) void {
    if (instr.size == 2) {
        if (instr.hw1 == trap) return out.put("trap", .{});
        out.put("udf ", .{});
        return out.imm(instr.hw1 & 0xFF);
    }
    out.put("udf.w ", .{});
    out.imm((@as(u32, instr.hw1 & 0xF) << 12) | (instr.hw2 & 0xFFF));
}
