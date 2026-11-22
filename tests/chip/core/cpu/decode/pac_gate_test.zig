//! Covers src/chip/core/cpu/decode/pac_gate.zig.
const ra8 = @import("ra8");
const std = @import("std");

const decode = ra8.chip.core.cpu.decode;
const Instr = ra8.chip.core.cpu.instr.Instr;
const pac_gate = decode.pac_gate;
const Profile = decode.profile.Profile;

fn wide(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

test "M55 and M33 allow PAC/PACBTI/AUT hint space while refusing PACG/AUTG/BXAUT" {
    const pac_hint = wide(0xF3AF, 0x801D);
    const pacbti_hint = wide(0xF3AF, 0x800D);
    const aut_hint = wide(0xF3AF, 0x802D);
    const pacg = wide(0xFB61, 0xF203);
    const autg = wide(0xFB51, 0x2F03);
    const bxaut = wide(0xFB5C, 0xCF1D);

    for ([_]Profile{ Profile.m55, Profile.m33 }) |p| {
        try std.testing.expect(pac_gate.allows(p, "pac", pac_hint));
        try std.testing.expect(pac_gate.allows(p, "pac", pacbti_hint));
        try std.testing.expect(pac_gate.allows(p, "pac", aut_hint));
        try std.testing.expect(!pac_gate.allows(p, "pac", pacg));
        try std.testing.expect(!pac_gate.allows(p, "pac", autg));
        try std.testing.expect(!pac_gate.allows(p, "pac", bxaut));
    }

    for ([_]Instr{ pac_hint, pacbti_hint, aut_hint, pacg, autg, bxaut }) |i| {
        try std.testing.expect(pac_gate.allows(Profile.m85, "pac", i));
    }
}

test "M55 and M33 refuse MRS and MSR targeting PAC_KEY_* while M85 allows them" {
    const mrs_p0 = wide(0xF3EF, 0x8020);
    const msr_u3 = wide(0xF380, 0x8827);
    const mrs_control = wide(0xF3EF, 0x8014);

    for ([_]Profile{ Profile.m55, Profile.m33 }) |p| {
        try std.testing.expect(!pac_gate.allows(p, "mrs_msr", mrs_p0));
        try std.testing.expect(!pac_gate.allows(p, "mrs_msr", msr_u3));
        try std.testing.expect(pac_gate.allows(p, "mrs_msr", mrs_control));
        try std.testing.expect(pac_gate.allows(p, "dp_reg", mrs_p0));
    }
    try std.testing.expect(pac_gate.allows(Profile.m85, "mrs_msr", mrs_p0));
    try std.testing.expect(pac_gate.allows(Profile.m85, "mrs_msr", msr_u3));
}
