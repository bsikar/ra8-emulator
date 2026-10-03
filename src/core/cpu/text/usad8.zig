//! Text for the usad8 group: USAD8 Rd, Rn, Rm, or USADA8 Rd, Rn, Rm, Ra when
//! Ra is not 1111.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const usad8 = @import("../ops/usad8.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = usad8.Fields.of(instr) orelse return;
    if (f.ra == usad8.encodings.no_ra) return out.regs3("usad8", f.rd, f.rn, f.rm);
    out.regs3("usada8", f.rd, f.rn, f.rm);
    out.put(", {s}", .{text.names[f.ra]});
}
