//! Text for the preload group: pld, pldw and pli in their immediate,
//! negative-immediate, literal and register forms.
//!
//! We drop a zero imm12 offset (`pld [r0]`) except on the literal
//! form (`pld [pc, #0]`), and prints every subtracted offset in hex, zero
//! included (`#-0x0`, `#-0x4`). An added offset follows the usual
//! decimal-below-ten rule.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const preload = @import("../ops/preload.zig");

const pc: u4 = 15;

pub fn print(instr: Instr, out: *text.Text) void {
    const kind = preload.kind(instr) orelse return;
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    out.put("{s} [", .{@tagName(kind)});
    out.reg(rn);
    const add = instr.hw1 & preload.encodings.imm12_bit != 0;
    if (rn == pc) {
        offset(out, add, instr.hw2 & 0xFFF, true);
    } else if (add) {
        offset(out, true, instr.hw2 & 0xFFF, false);
    } else if (instr.hw2 & 0x0F00 == preload.encodings.t2_negative) {
        offset(out, false, instr.hw2 & 0xFF, false);
    } else {
        out.put(", ", .{});
        out.reg(@intCast(instr.hw2 & 0xF));
        const shift = (instr.hw2 >> 4) & 3;
        if (shift != 0) out.put(", lsl #{d}", .{shift});
    }
    out.put("]", .{});
}

/// `, #n` or `, #-0xn`; a zero added offset is left out unless `keep_zero`.
fn offset(out: *text.Text, add: bool, value: u32, keep_zero: bool) void {
    if (!add) return out.put(", #-0x{x}", .{value});
    if (value == 0 and !keep_zero) return;
    out.put(", ", .{});
    out.imm(value);
}
