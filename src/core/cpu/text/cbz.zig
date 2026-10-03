//! Text for the cbz group: CBZ and CBNZ with their absolute target.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const hw1 = instr.hw1;
    const offset: i32 = @intCast(((hw1 >> 3) & 0x40) | ((hw1 >> 2) & 0x3E));
    out.put("{s} {s}, ", .{ if (hw1 & 0x0800 != 0) "cbnz" else "cbz", text.names[text.low(hw1, 0)] });
    out.target(instr.address, offset);
}
