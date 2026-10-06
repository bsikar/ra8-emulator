//! Text for the mrs_msr group: MRS and MSR (register), in the spelling
//! the parity digests pin. The APSR-family MSR names its mask (`msr apsr_nzcvq, r4`,
//! `_g`, `_nzcvqg`); every other register prints bare (`mrs r3, msp_ns`).
//!
//! The reference disassembler could not decode the PAC key registers
//! (SYSm 0x20 to 0x27), so
//! those print the Arm names `pac_key_p_0` to `pac_key_u_3` with no check
//! against it.
const Instr = @import("../instr.zig").Instr;
const text = @import("text.zig");

const psr = [8][]const u8{ "apsr", "iapsr", "eapsr", "xpsr", "", "ipsr", "epsr", "iepsr" };
const stack = [4][]const u8{ "msp", "psp", "msplim", "psplim" };
const mask_reg = [5][]const u8{ "primask", "basepri", "basepri_max", "faultmask", "control" };
const pac = [8][]const u8{
    "pac_key_p_0", "pac_key_p_1", "pac_key_p_2", "pac_key_p_3",
    "pac_key_u_0", "pac_key_u_1", "pac_key_u_2", "pac_key_u_3",
};
const mask_suffix = [4][]const u8{ "", "_g", "_nzcvq", "_nzcvqg" };

/// The base name of SYSm `n`, `_ns` included; `ns` says whether to add it.
fn base(n: u8) []const u8 {
    const low = n & 0x7F;
    return switch (low) {
        0...7 => psr[low],
        8...11 => stack[low - 8],
        16...20 => mask_reg[low - 16],
        24 => "sp",
        0x20...0x27 => pac[low - 0x20],
        else => "",
    };
}

fn name(out: *text.Text, n: u8) void {
    out.put("{s}{s}", .{ base(n), if (n & 0x80 != 0) "_ns" else "" });
}

pub fn print(instr: Instr, out: *text.Text) void {
    const n: u8 = @truncate(instr.hw2);
    if (instr.hw1 & 0xFFF0 != 0xF380) {
        out.put("mrs ", .{});
        out.reg(@intCast((instr.hw2 >> 8) & 0xF));
        out.put(", ", .{});
        return name(out, n);
    }
    out.put("msr ", .{});
    name(out, n);
    if (n <= 3) out.put("{s}", .{mask_suffix[(instr.hw2 >> 10) & 0x3]});
    out.put(", ", .{});
    out.reg(@intCast(instr.hw1 & 0xF));
}
