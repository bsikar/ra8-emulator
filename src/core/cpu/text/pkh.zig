//! Text for the pkh group, in the spelling the parity digests pin: PKHBT drops a zero
//! shift (`pkhbt r0, r1, r2`) and prints `lsl #n` otherwise; PKHTB always
//! prints its shift, with #0 shown as `asr #0x20`.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");
const pkh = @import("../ops/pkh.zig");

pub fn print(instr: Instr, out: *text.Text) void {
    const f = pkh.Fields.of(instr) orelse return;
    out.regs3(if (f.tb) "pkhtb" else "pkhbt", f.rd, f.rn, f.rm);
    if (f.tb) {
        out.put(", asr ", .{});
        return out.imm(if (f.imm5 == 0) 32 else f.imm5);
    }
    if (f.imm5 == 0) return;
    out.put(", lsl ", .{});
    out.imm(f.imm5);
}
