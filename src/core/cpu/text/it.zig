//! Text for the it group: IT with its then/else letters and the first
//! condition. A mask bit equal to firstcond[0] is a `t`, otherwise an `e`;
//! the lowest set bit ends the mask.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const firstcond: u4 = @intCast((instr.hw1 >> 4) & 0xF);
    const mask: u4 = @intCast(instr.hw1 & 0xF);
    out.put("it", .{});
    var bit: u3 = 3;
    while (bit > @ctz(mask)) : (bit -= 1) {
        const same = (mask >> @intCast(bit)) & 1 == firstcond & 1;
        out.put("{s}", .{if (same) "t" else "e"});
    }
    out.put(" {s}", .{text.conds[firstcond]});
}
