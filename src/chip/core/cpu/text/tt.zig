//! Text for the tt group: TT, TTT, TTA and TTAT Rd, Rn, in the spelling
//! the parity digests pin (no `.w`). The fields come from src/chip/core/tt.zig's decode, the
//! one the executor uses.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const tt = @import("../../tt.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const form = tt.decode(instr.hw1, instr.hw2) orelse return;
    const mnemonic = if (form.alternate)
        (if (form.unprivileged) "ttat" else "tta")
    else
        (if (form.unprivileged) "ttt" else "tt");
    out.regs2(mnemonic, form.rd, form.rn);
}
