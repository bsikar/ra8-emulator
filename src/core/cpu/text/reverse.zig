//! Text for the reverse group: REV, REV16 and REVSH, 16-bit. Kind 2 is
//! unallocated and the group never claims it.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

const mnemonics = [4][]const u8{ "rev", "rev16", "", "revsh" };

pub fn print(instr: Instr, out: *text.Text) void {
    out.regs2(mnemonics[(instr.hw1 >> 6) & 0x3], text.low(instr.hw1, 0), text.low(instr.hw1, 3));
}
