//! Text for the exclusive group: LDREX and STREX with their byte, halfword
//! and acquire/release forms, and CLREX, in the spelling the parity digests pin. No form
//! carries `.w`.
//!
//! A store prints its status register first (`strex r2, r0, [r1]`). Only
//! the word forms take an offset: a zero one is dropped, others use the
//! decimal-below-ten rule (`#4`, `#0x3fc`).
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const exclusive = @import("../ops/exclusive.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    if (instr.size == 4 and instr.hw1 == exclusive.encodings.clrex_hw1 and instr.hw2 == exclusive.encodings.clrex_hw2)
        return out.put("clrex", .{});
    const a = exclusive.access(instr) orelse return;
    out.put("{s} ", .{mnemonic(instr, a.load)});
    if (!a.load) {
        out.reg(a.rd);
        out.put(", ", .{});
    }
    out.reg(a.rt);
    out.put(", [", .{});
    out.reg(a.rn);
    if (a.offset != 0) {
        out.put(", ", .{});
        out.imm(a.offset);
    }
    out.put("]", .{});
}

/// The word forms sit at their own hw1; the narrow and acquire/release
/// forms are picked by hw2[7:4], as exclusive.zig decodes them.
fn mnemonic(instr: Instr, load: bool) []const u8 {
    const narrow = instr.hw1 & exclusive.encodings.rn_mask;
    if (narrow == exclusive.encodings.ldrex) return "ldrex";
    if (narrow == exclusive.encodings.strex) return "strex";
    const names: [3][2][]const u8 = .{
        .{ "ldrexb", "strexb" },
        .{ "ldrexh", "strexh" },
        .{ "ldaex", "stlex" },
    };
    const pick: usize = if (load) 0 else 1;
    return switch ((instr.hw2 >> 4) & 0xF) {
        0x4 => names[0][pick],
        0x5 => names[1][pick],
        0xC => if (load) "ldaexb" else "stlexb",
        0xD => if (load) "ldaexh" else "stlexh",
        else => names[2][pick],
    };
}
