//! Text for the hint group, 16-bit: NOP, YIELD, WFE, WFI and SEV by name, and
//! any other hint as `hint #n`.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

const named = [5][]const u8{ "nop", "yield", "wfe", "wfi", "sev" };

pub fn print(instr: Instr, out: *text.Text) void {
    const hint = (instr.hw1 >> 4) & 0xF;
    if (hint < named.len) return out.put("{s}", .{named[hint]});
    out.put("hint ", .{});
    out.imm(hint);
}
