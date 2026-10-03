//! Text for the umaal group: UMAAL RdLo, RdHi, Rn, Rm.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const umaal = @import("../ops/umaal.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = umaal.Fields.of(instr) orelse return;
    out.regs3("umaal", f.rd_lo, f.rd_hi, f.rn);
    out.put(", {s}", .{text.names[f.rm]});
}
