//! Text for the bitfield group: SBFX, UBFX, BFI and BFC (BFI with Rn of
//! PC). Capstone prints the field as lsb and width, both as ordinary
//! immediates; the insert's width comes from its msb.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const Fields = @import("../ops/bitfield.zig").Fields;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = Fields.of(instr).?;
    const width: u32 = switch (f.kind) {
        .bfi => @as(u32, f.top) - f.lsb + 1,
        .sbfx, .ubfx => @as(u32, f.top) + 1,
    };
    if (f.kind == .bfi and f.rn == 15) {
        out.put("bfc {s}, ", .{text.names[f.rd]});
    } else {
        out.put("{s} {s}, {s}, ", .{ @tagName(f.kind), text.names[f.rd], text.names[f.rn] });
    }
    out.imm(f.lsb);
    out.put(", ", .{});
    out.imm(width);
}
