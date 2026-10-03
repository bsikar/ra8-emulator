//! Text for the saturate group: SSAT and USAT with an optional shift of Rn.
//! Capstone prints the saturate position as the bit count (sat_imm + 1 for
//! SSAT), and the shift amount as an ordinary immediate; LSL #0 is omitted.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const Fields = @import("../ops/saturate.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const bits: u32 = if (f.unsigned) f.sat_imm else @as(u32, f.sat_imm) + 1;
    out.put("{s} {s}, ", .{ if (f.unsigned) "usat" else "ssat", text.names[f.rd] });
    out.imm(bits);
    out.put(", {s}", .{text.names[f.rn]});
    if (!f.asr and f.amount == 0) return;
    out.put(", {s} ", .{if (f.asr) "asr" else "lsl"});
    out.imm(f.amount);
}
