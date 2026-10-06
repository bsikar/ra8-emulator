//! Text for the acq_rel group: LDA, LDAB, LDAH, STL, STLB and STLH, in
//! the spelling the parity digests pin. No form carries `.w` or an offset: `lda r0, [r1]`.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const acq_rel = @import("../ops/acq_rel.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const a = acq_rel.access(instr) orelse return;
    out.put("{s}{s} ", .{ if (a.load) "lda" else "stl", suffix(a.size) });
    out.reg(a.rt);
    out.put(", [", .{});
    out.reg(a.rn);
    out.put("]", .{});
}

fn suffix(size: u3) []const u8 {
    return switch (size) {
        1 => "b",
        2 => "h",
        else => "",
    };
}
