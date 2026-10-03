//! Text for the csel group (Armv8.1-M), in Arm ARM syntax: CSEL, CSINC,
//! CSINV and CSNEG, or the alias the Arm ARM prefers. With Rn == Rm (not the
//! zero register) CSINC, CSINV and CSNEG print as CINC, CINV and CNEG; with
//! both the zero register, CSINC and CSINV print as CSET and CSETM. An alias
//! carries the inverted condition. Register 0b1111 in Rn or Rm prints `zr`.
//! Capstone 5 has no Armv8.1-M, so these are tested against the Arm ARM.
const Instr = @import("../instr.zig").Instr;
const csel = @import("../../csel.zig");
const text = @import("text.zig");

const zr = csel.encoding.zero_register;

pub fn print(instr: Instr, out: *text.Text) void {
    const f = csel.decode(instr.hw1, instr.hw2) orelse return;
    const rd = text.names[f.destination];
    const inverted = text.conds[f.condition ^ 1];
    if (f.then_source == f.else_source and f.kind != .sel) {
        if (f.then_source != zr) {
            return out.put("{s} {s}, {s}, {s}", .{ alias(f.kind), rd, text.names[f.then_source], inverted });
        }
        if (f.kind == .inc) return out.put("cset {s}, {s}", .{ rd, inverted });
        if (f.kind == .inv) return out.put("csetm {s}, {s}", .{ rd, inverted });
    }
    out.put("{s} {s}, {s}, {s}, {s}", .{ mnemonic(f.kind), rd, name(f.then_source), name(f.else_source), text.conds[f.condition] });
}

fn name(r: u4) []const u8 {
    return if (r == zr) "zr" else text.names[r];
}

fn mnemonic(kind: csel.Kind) []const u8 {
    return switch (kind) {
        .sel => "csel",
        .inc => "csinc",
        .inv => "csinv",
        .neg => "csneg",
    };
}

fn alias(kind: csel.Kind) []const u8 {
    return switch (kind) {
        .sel => "csel",
        .inc => "cinc",
        .inv => "cinv",
        .neg => "cneg",
    };
}
