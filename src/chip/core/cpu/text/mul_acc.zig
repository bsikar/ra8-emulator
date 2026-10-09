//! Text for the mul_acc group: mul Rd, Rn, Rm (Ra = PC) and mla/mls Rd, Rn,
//! Rm, Ra. We print no .w on any of them.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const Fields = @import("../ops/mul_acc.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    out.put("{s} {s}, {s}, {s}", .{ @tagName(f.kind), text.names[f.rd], text.names[f.rn], text.names[f.rm] });
    if (f.kind != .mul) out.put(", {s}", .{text.names[f.ra]});
}
