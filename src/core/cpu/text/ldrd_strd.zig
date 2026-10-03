//! Text for the ldrd_strd group: `ldrd`/`strd rt, rt2` with an immediate
//! offset, in Capstone 5's spelling. No form carries `.w`.
//!
//! An offset form drops a zero added offset (`[r0]`) and prints a subtracted
//! one in hex, zero included (`#-0x0`). A pre-indexed form keeps a zero
//! (`[r0, #0]!`) and also prints a subtracted offset in hex. A post-indexed
//! form uses the decimal-below-ten rule on both signs (`#-0`, `#-8`, `#-0xc`).
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const Form = @import("../ops/ldrd_strd.zig").Form;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Form.of(instr) orelse return;
    out.put("{s} ", .{if (f.load) "ldrd" else "strd"});
    out.reg(f.rt);
    out.put(", ", .{});
    out.reg(f.rt2);
    out.put(", [", .{});
    out.reg(f.rn);
    if (!f.index) {
        out.put("], ", .{});
        if (f.add) return out.imm(f.offset);
        if (f.offset < text.decimal_below) return out.put("#-{d}", .{f.offset});
        return out.put("#-0x{x}", .{f.offset});
    }
    if (!f.add) {
        out.put(", #-0x{x}", .{f.offset});
    } else if (f.offset != 0 or f.wback) {
        out.put(", ", .{});
        out.imm(f.offset);
    }
    out.put("]{s}", .{if (f.wback) "!" else ""});
}
