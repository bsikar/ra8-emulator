//! Text for the svc group: SVC #imm8.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    out.put("svc ", .{});
    out.imm(instr.hw1 & 0xFF);
}
