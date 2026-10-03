//! Text for the sat16 group: SSAT16 and USAT16. Capstone prints the
//! saturate position as the bit count, sat_imm + 1 for SSAT16.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const Fields = @import("../ops/sat16.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const bits: u32 = if (f.signed) @as(u32, f.sat_imm) + 1 else f.sat_imm;
    out.put("{s} {s}, ", .{ if (f.signed) "ssat16" else "usat16", text.names[f.rd] });
    out.imm(bits);
    out.put(", {s}", .{text.names[f.rn]});
}
