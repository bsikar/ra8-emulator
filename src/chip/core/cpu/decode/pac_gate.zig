//! Per-core Armv8.1-M PACBTI decoding gate.
//!
//! Keeps `ops/table.zig` group membership untouched while enforcing PACBTI
//! requirements per core profile:
//!   - Hint-space PAC, PACBTI, and AUT (0xF3AF 0x800D/801D/802D) decode on any
//!     Armv8-M Mainline core and execute as NOPs when `Profile.pacbti` is false.
//!   - General PACG, AUTG, and BXAUT instructions and `MRS`/`MSR PAC_KEY_*`
//!     encodings require `Profile.pacbti` and otherwise fall through as UNDEFINED.
const Instr = @import("../instr.zig").Instr;
const pac = @import("../ops/pac.zig");
const profile = @import("../profile.zig");
const std = @import("std");
const sysreg = @import("../sysreg.zig");

pub fn allows(core: profile.Profile, group_name: []const u8, instr: Instr) bool {
    if (core.pacbti or instr.size != 4) return true;
    if (std.mem.eql(u8, group_name, "pac")) return isPacHint(instr);
    if (isPacKeyMove(instr) and std.mem.eql(u8, group_name, "mrs_msr")) return false;
    return true;
}

fn isPacHint(instr: Instr) bool {
    return instr.size == 4 and instr.hw1 == pac.encodings.hint_hw1 and instr.hw2 & 0xFF00 == 0x8000;
}

fn isPacKeyMove(instr: Instr) bool {
    if (instr.size != 4) return false;
    return sysreg.isPacKey(@truncate(instr.hw2));
}
