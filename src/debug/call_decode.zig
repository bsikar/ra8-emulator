//! Whether a Thumb instruction is a call, from its bytes alone.
//!
//! A step over needs exactly one fact about the instruction it starts on:
//! does it call. The driver already has the bytes in hand when it feeds the
//! stop machine, so the answer is read here, without a disassembler, and the
//! same answer serves Unicorn now and the Zig core later.
//!
//! Three encodings call on Armv8-M: BL and BLX with an immediate (32-bit),
//! and BLX with a register (16-bit). Everything else, branches included, is
//! not a call and a step over it is a single step.
const std = @import("std");

pub const encoding = struct {
    /// The first halfword of every 32-bit BL and BLX(imm): 11110 S imm10.
    pub const bl_prefix_mask: u16 = 0xF800;
    pub const bl_prefix: u16 = 0xF000;
    /// The second halfword of BL: 11 J1 1 J2 imm11.
    pub const bl_suffix_mask: u16 = 0xD000;
    pub const bl_suffix: u16 = 0xD000;
    /// The second halfword of BLX(imm): 11 J1 0 J2 imm10H 0.
    pub const blx_imm_suffix_mask: u16 = 0xD001;
    pub const blx_imm_suffix: u16 = 0xC000;
    /// BLX Rm: 0100 0111 1 Rm 000.
    pub const blx_reg_mask: u16 = 0xFF87;
    pub const blx_reg: u16 = 0x4780;
};

/// Whether the instruction in `bytes` is a call. `bytes` holds the
/// instruction as fetched, little-endian, two or four bytes long.
pub fn isCall(bytes: []const u8) bool {
    if (bytes.len < 2) return false;
    const first = std.mem.readInt(u16, bytes[0..2], .little);
    if (first & encoding.blx_reg_mask == encoding.blx_reg) return true;
    if (bytes.len < 4) return false;
    if (first & encoding.bl_prefix_mask != encoding.bl_prefix) return false;
    const second = std.mem.readInt(u16, bytes[2..4], .little);
    if (second & encoding.bl_suffix_mask == encoding.bl_suffix) return true;
    return second & encoding.blx_imm_suffix_mask == encoding.blx_imm_suffix;
}
