//! Text for the misc_wide group: REV, REV16, RBIT, REVSH and CLZ (32-bit),
//! in Capstone 5's spelling. The byte reversals carry `.w`; RBIT and CLZ
//! have no narrow form and print bare: `rev.w r0, r1`, `clz r0, r1`.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const misc_wide = @import("../ops/misc_wide.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = misc_wide.Fields.of(instr) orelse return;
    const mnemonic = switch (f.kind) {
        .rev => "rev.w",
        .rev16 => "rev16.w",
        .revsh => "revsh.w",
        .rbit => "rbit",
        .clz => "clz",
    };
    out.regs2(mnemonic, f.rd, f.rm);
}
