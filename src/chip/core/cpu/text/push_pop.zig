//! Text for the push_pop group: bit 8 adds LR to a PUSH and PC to a POP.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

const lr_bit: u16 = 1 << 14;
const pc_bit: u16 = 1 << 15;

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    const pop = hw1 & 0x0800 != 0;
    const extra: u16 = if (hw1 & 0x0100 == 0) 0 else if (pop) pc_bit else lr_bit;
    out.put("{s} ", .{if (pop) "pop" else "push"});
    out.list((hw1 & 0xFF) | extra);
}
