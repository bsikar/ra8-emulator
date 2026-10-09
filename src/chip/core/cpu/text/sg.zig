//! Text for the sg group: SG, the Secure Gateway (0xE97F 0xE97F).
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    _ = instr;
    out.put("sg", .{});
}
