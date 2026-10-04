//! Conformance vectors for the decode group `pac` (RA8EMU-278): PAC,
//! PACBTI, AUT, PACG, AUTG and BXAUT (Armv8.1-M PACBTI). Expected values
//! are worked from the Arm ARM (DDI0553): the PAC is the low word of QARMA5
//! over the zero-extended pointer and modifier, keyed by PAC_KEY_P when the
//! core is privileged and PAC_KEY_U when not; CONTROL.PAC_EN (privileged)
//! or CONTROL.UPAC_EN (unprivileged) turns signing on, and with it off a
//! sign leaves its destination alone and an authentication passes. PAC and
//! PACBTI sign LR with SP into R12, PACBTI also clearing EPSR.B; AUT checks
//! R12 against LR and SP; PACG and AUTG take Rn and Rm; BXAUT checks Ra
//! against Rn and Rm, then branches to Rn with interworking. A failed check
//! is an INVSTATE UsageFault with nothing changed. The PAC words below
//! come from src/core/cpu/qarma.zig, which matches the published QARMA5
//! 64-bit known-answer vector (tests/core/cpu/qarma_test.zig). SP or PC
//! where the Arm ARM refuses them, other hint numbers and the 16-bit
//! space are left unclaimed.
const vector = @import("../vector.zig");

pub const key_p: [4]u32 = .{ 0x0123_4567, 0x89AB_CDEF, 0xFEDC_BA98, 0x7654_3210 };
pub const key_u: [4]u32 = .{ 0x1111_1111, 0x2222_2222, 0x3333_3333, 0x4444_4444 };
pub const lr_in: u32 = 0x2000_0181;
pub const sp_in: u32 = 0x2000_0300;
pub const r0_in: u32 = 0xDEAD_0000;
pub const r1_in: u32 = 0x1234_5678;
pub const r2_in: u32 = 0x9ABC_DEF0;
pub const r3_in: u32 = 0x2000_0241;
pub const r12_in: u32 = 0xDEAD_BEEF;
pub const pc_in: u32 = 0x2000_0100;
/// CONTROL.PAC_EN and UPAC_EN, and nPRIV.
const both: u32 = 0xC0;
const unpriv_on: u32 = 0x81;
const unpriv_off: u32 = 0x41;

/// QARMA5 PACs: LR with SP under each key, R1 with R2 under each key, and
/// R3 with R2 under the privileged key.
const p_lr: u32 = 0x0E77_9E89;
const u_lr: u32 = 0xC59B_C99A;
const p_g: u32 = 0x50F3_3213;
const u_g: u32 = 0xB15F_03E8;
const p_b: u32 = 0x87BE_8711;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    control: u32 = both,
    r0: u32 = r0_in,
    r12: u32 = r12_in,
};

/// How the instruction ended.
pub const Fault = enum { none, invalid_state, other };

/// Whether the group claims the encoding, how it ended, R0, R12, PC, the
/// Thumb bit and EPSR.B after (B is set before every run).
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    r0: u32 = r0_in,
    r12: u32 = r12_in,
    pc: u32 = pc_in,
    thumb: bool = true,
    bti: bool = true,
};

const V = vector.Vector(In, Out);
const group = "pac";
pub const none: Out = .{ .claimed = false, .r0 = 0, .r12 = 0, .pc = 0, .thumb = false, .bti = false };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

const hint: u16 = 0xF3AF;
const failed: Fault = .invalid_state;

pub const all = lr_forms ++ general ++ unclaimed;

const lr_forms = [_]V{
    vec("pac signs lr with sp under the privileged key", .{ .hw1 = hint, .hw2 = 0x801D }, .{ .r12 = p_lr }),
    vec("pac with signing off leaves r12", .{ .hw1 = hint, .hw2 = 0x801D, .control = 0 }, .{}),
    vec("pac unprivileged uses the unprivileged key", .{ .hw1 = hint, .hw2 = 0x801D, .control = unpriv_on }, .{ .r12 = u_lr }),
    vec("pac unprivileged with only pac_en leaves r12", .{ .hw1 = hint, .hw2 = 0x801D, .control = unpriv_off }, .{}),
    vec("pac privileged with only upac_en leaves r12", .{ .hw1 = hint, .hw2 = 0x801D, .control = 0x80 }, .{}),
    vec("pacbti signs and clears epsr.b", .{ .hw1 = hint, .hw2 = 0x800D }, .{ .r12 = p_lr, .bti = false }),
    vec("pacbti with signing off still clears epsr.b", .{ .hw1 = hint, .hw2 = 0x800D, .control = 0 }, .{ .bti = false }),
    vec("aut passes with the right code", .{ .hw1 = hint, .hw2 = 0x802D, .r12 = p_lr }, .{ .r12 = p_lr }),
    vec("aut with a wrong code faults", .{ .hw1 = hint, .hw2 = 0x802D }, .{ .fault = failed }),
    vec("aut unprivileged passes with the unprivileged code", .{ .hw1 = hint, .hw2 = 0x802D, .control = unpriv_on, .r12 = u_lr }, .{ .r12 = u_lr }),
    vec("aut unprivileged refuses the privileged code", .{ .hw1 = hint, .hw2 = 0x802D, .control = unpriv_on, .r12 = p_lr }, .{ .fault = failed, .r12 = p_lr }),
    vec("aut with signing off passes any code", .{ .hw1 = hint, .hw2 = 0x802D, .control = 0 }, .{}),
};

const general = [_]V{
    vec("pacg r0, r1, r2", .{ .hw1 = 0xFB61, .hw2 = 0xF002 }, .{ .r0 = p_g }),
    vec("pacg r0, r1, r2 unprivileged", .{ .hw1 = 0xFB61, .hw2 = 0xF002, .control = unpriv_on }, .{ .r0 = u_g }),
    vec("pacg with signing off leaves r0", .{ .hw1 = 0xFB61, .hw2 = 0xF002, .control = 0 }, .{}),
    vec("pacg r12, r1, r2", .{ .hw1 = 0xFB61, .hw2 = 0xFC02 }, .{ .r12 = p_g }),
    vec("autg r0, r1, r2 passes with the right code", .{ .hw1 = 0xFB51, .hw2 = 0x0F02, .r0 = p_g }, .{ .r0 = p_g }),
    vec("autg with a wrong code faults", .{ .hw1 = 0xFB51, .hw2 = 0x0F02 }, .{ .fault = failed }),
    vec("autg with signing off passes any code", .{ .hw1 = 0xFB51, .hw2 = 0x0F02, .control = 0 }, .{}),
    vec("bxaut r0, r3, r2 branches with interworking", .{ .hw1 = 0xFB53, .hw2 = 0x0F12, .r0 = p_b }, .{ .r0 = p_b, .pc = 0x2000_0240 }),
    vec("bxaut with a wrong code faults and stays", .{ .hw1 = 0xFB53, .hw2 = 0x0F12 }, .{ .fault = failed }),
    vec("bxaut with signing off still branches", .{ .hw1 = 0xFB53, .hw2 = 0x0F12, .control = 0 }, .{ .pc = 0x2000_0240 }),
    vec("bxaut ip, lr, sp returns", .{ .hw1 = 0xFB5E, .hw2 = 0xCF1D, .r12 = p_lr }, .{ .r12 = p_lr, .pc = 0x2000_0180 }),
};

const unclaimed = [_]V{
    bad("hint 0x4D is unclaimed", hint, 0x804D),
    bad("hint 0x3D is unclaimed", hint, 0x803D),
    bad("nop is not pac", hint, 0x8000),
    bad("pacg into sp is unclaimed", 0xFB61, 0xFD02),
    bad("pacg into pc is unclaimed", 0xFB61, 0xFF02),
    bad("pacg rn = pc is unclaimed", 0xFB6F, 0xF002),
    bad("pacg rm = pc is unclaimed", 0xFB61, 0xF00F),
    bad("pacg hw2[7:4] not zero is unclaimed", 0xFB61, 0xF012),
    bad("autg form 0x0F20 is unclaimed", 0xFB51, 0x0F22),
    bad("autg ra = sp is unclaimed", 0xFB51, 0xDF02),
    bad("autg ra = pc is unclaimed", 0xFB51, 0xFF02),
    bad("autg rn = pc is unclaimed", 0xFB5F, 0x0F02),
    bad("autg rm = pc is unclaimed", 0xFB51, 0x0F0F),
    bad("bxaut rn = sp is unclaimed", 0xFB5D, 0x0F12),
    vec("the 16-bit space is unclaimed", .{ .hw1 = hint, .hw2 = 0x801D, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
