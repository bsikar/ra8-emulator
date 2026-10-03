//! Text for the clrm group (Armv8.1-M), in Arm ARM syntax: `clrm {r0, lr,
//! apsr}`, R0 to R12 low first, then LR, then APSR when hw2[15] is set.
//! Register names follow the rest of this disassembler (r9-r12 as sb, sl, fp
//! and ip). Capstone 5 reads the encoding as an LDM from PC.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

/// hw2[14:0]: R0 to R12, then SP (never set, decode refuses it) and LR.
const core_registers = 15;
const apsr: u16 = 1 << 15;

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("clrm {{", .{});
    var first = true;
    for (0..core_registers) |r| {
        if (instr.hw2 & (@as(u16, 1) << @intCast(r)) == 0) continue;
        out.put("{s}{s}", .{ if (first) "" else ", ", text.names[r] });
        first = false;
    }
    if (instr.hw2 & apsr != 0) out.put("{s}apsr", .{if (first) "" else ", "});
    out.put("}}", .{});
}
