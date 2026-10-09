//! Text for the special_data group: ADD, CMP and MOV on any register, BX and
//! BLX. ADD with SP as the second operand prints as `add rd, sp, rd`.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

const sp: u4 = 13;

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    const d: u4 = @intCast(((hw1 >> 4) & 0x8) | (hw1 & 0x7));
    const m: u4 = @intCast((hw1 >> 3) & 0xF);
    switch ((hw1 >> 8) & 0x3) {
        0 => if (m == sp) out.regs3("add", d, sp, d) else out.regs2("add", d, m),
        1 => out.regs2("cmp", d, m),
        2 => out.regs2("mov", d, m),
        else => out.put("{s} {s}", .{ if (hw1 & 0x80 != 0) "blx" else "bx", text.names[m] }),
    }
}
