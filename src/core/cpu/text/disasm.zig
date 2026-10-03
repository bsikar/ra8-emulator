//! The Zig core's own disassembler (RA8EMU-17): decode the instruction with
//! the core's decode table, then let that group's printer write it.
const decode = @import("../decode.zig");
const Instr = @import("../instr.zig").Instr;
const table = @import("table.zig");
const Text = @import("text.zig").Text;

/// The text of `instr`, or null when no group claims it or its group has no
/// printer yet.
pub fn one(instr: Instr) ?Text {
    const hit = decode.decode(instr) orelse return null;
    const print = table.find(hit.group) orelse return null;
    var out: Text = .{};
    print(instr, &out);
    return out;
}
