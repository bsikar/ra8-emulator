//! Text for the pac group (Armv8.1-M PACBTI), in Arm ARM syntax with the
//! house register names: `pac ip, lr, sp`, `pacbti ip, lr, sp`,
//! `aut ip, lr, sp`, `pacg rd, rn, rm`, `autg ra, rn, rm` and
//! `bxaut ra, rn, rm`. The hint forms always name R12, LR and SP; the
//! register forms take Rn from hw1[3:0], Rm from hw2[3:0], and Rd (PACG,
//! hw2[11:8]) or Ra (AUTG and BXAUT, hw2[15:12]).
const Instr = @import("../instr.zig").Instr;
const ops = @import("../ops/pac.zig");
const text = @import("text.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const e = ops.encodings;
    if (instr.hw1 == e.hint_hw1) {
        const mnemonic = switch (@as(u8, @truncate(instr.hw2))) {
            e.pacbti => "pacbti",
            e.pac => "pac",
            else => "aut",
        };
        return out.put("{s} ip, lr, sp", .{mnemonic});
    }
    const rn = text.names[instr.hw1 & 0xF];
    const rm = text.names[instr.hw2 & 0xF];
    if (instr.hw1 & e.pacg_mask == e.pacg) {
        return out.put("pacg {s}, {s}, {s}", .{ text.names[(instr.hw2 >> 8) & 0xF], rn, rm });
    }
    const mnemonic = if (instr.hw2 & 0x0FF0 == 0x0F10) "bxaut" else "autg";
    out.put("{s} {s}, {s}, {s}", .{ mnemonic, text.names[instr.hw2 >> 12], rn, rm });
}
