//! Conformance vectors for the decode group `mrs_msr` (RA8EMU-278): MRS
//! (T1) and MSR (T1, register) on the xPSR views, the stack pointers and
//! limits, the masks, CONTROL, a PAC key and a Non-secure alias. Expected
//! values are worked from the Arm ARM (DDI0553): EPSR reads zero, the APSR
//! forms write NZCVQ under mask bit 1 and GE under mask bit 0, unprivileged
//! code reads zero from and cannot write the stack pointers and masks,
//! BASEPRI_MAX only raises the mask, FAULTMASK cannot be set at priority -1
//! or above, Handler mode keeps SPSEL, CONTROL.SFPA is not MSR-writable, the
//! limits drop bits 2:0, and Secure code reaches the Non-secure bank through
//! the _NS aliases. SP or PC as the core register, an unmodelled SYSm, an
//! MSR mask of 00 or a non-10 mask on a non-xPSR register are unclaimed.
const vector = @import("../vector.zig");

/// The core state each vector starts from.
pub const seed = struct {
    pub const r0: u32 = 0xDEAD_0000;
    /// N, C and Q with GE = 0111.
    pub const apsr: u32 = 0xA807_0000;
    pub const msp: u32 = 0x2000_1000;
    pub const psp: u32 = 0x2000_0800;
    pub const msplim: u32 = 0x2000_0000;
    pub const psplim: u32 = 0x2000_0400;
    pub const primask: u32 = 1;
    pub const basepri: u32 = 0x40;
    /// MSP_NS in the other (Non-secure) bank; the core runs Secure.
    pub const ns_msp: u32 = 0x3000_0000;
};

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// IPSR; non-zero puts the core in Handler mode.
    ipsr: u16 = 0,
    /// CONTROL.nPRIV in Thread mode.
    npriv: bool = false,
    /// What MSR's source register r1 holds.
    rs: u32 = 0,
};

/// Whether the group claims the encoding, then the state after.
pub const Out = struct {
    claimed: bool = true,
    r0: u32 = seed.r0,
    /// r12, zero before the instruction.
    r12: u32 = 0,
    /// NZCVQ and GE.
    apsr: u32 = seed.apsr,
    primask: u32 = seed.primask,
    basepri: u32 = seed.basepri,
    faultmask: u32 = 0,
    control: u32 = 0,
    msp: u32 = seed.msp,
    psp: u32 = seed.psp,
    msplim: u32 = seed.msplim,
    ns_msp: u32 = seed.ns_msp,
};

const V = vector.Vector(In, Out);
const group = "mrs_msr";
const none: Out = .{ .claimed = false, .r0 = 0, .apsr = 0, .primask = 0, .basepri = 0, .msp = 0, .psp = 0, .msplim = 0, .ns_msp = 0 };

const mrs_hw1 = 0xF3EF;
/// MSR with r1 as the source.
const msr_hw1 = 0xF381;

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

/// MRS r0, SYSm in Thread mode, privileged.
fn mrs(name: []const u8, sysm: u16, r0: u32) V {
    return vec(name, .{ .hw1 = mrs_hw1, .hw2 = 0x8000 | sysm }, .{ .r0 = r0 });
}

/// MSR SYSm, r1 with mask 10 (or `mask`) from privileged Thread mode.
fn msr(sysm: u16, mask: u16, rs: u32) In {
    return .{ .hw1 = msr_hw1, .hw2 = 0x8000 | (mask << 10) | sysm, .rs = rs };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

pub const all = reads ++ writes ++ unclaimed;

const reads = [_]V{
    mrs("mrs apsr reads NZCVQ and GE", 0, seed.apsr),
    mrs("mrs ipsr in Thread mode is zero", 5, 0),
    mrs("mrs epsr reads zero", 6, 0),
    mrs("mrs eapsr reads the APSR part", 2, seed.apsr),
    vec("mrs xpsr in Handler mode", .{ .hw1 = mrs_hw1, .hw2 = 0x8003, .ipsr = 11 }, .{ .r0 = seed.apsr | 11 }),
    vec("mrs iapsr in Handler mode", .{ .hw1 = mrs_hw1, .hw2 = 0x8001, .ipsr = 11 }, .{ .r0 = seed.apsr | 11 }),
    vec("mrs iepsr reads only IPSR", .{ .hw1 = mrs_hw1, .hw2 = 0x8007, .ipsr = 11 }, .{ .r0 = 11 }),
    mrs("mrs msp", 8, seed.msp),
    mrs("mrs psp", 9, seed.psp),
    mrs("mrs msplim", 10, seed.msplim),
    mrs("mrs psplim", 11, seed.psplim),
    mrs("mrs primask", 16, seed.primask),
    mrs("mrs basepri", 17, seed.basepri),
    mrs("mrs basepri_max reads basepri", 18, seed.basepri),
    mrs("mrs faultmask", 19, 0),
    mrs("mrs control", 20, 0),
    mrs("mrs pac_key_p_0", 0x20, 0),
    mrs("mrs msp_ns from Secure", 0x88, seed.ns_msp),
    vec("unprivileged mrs msp reads zero", .{ .hw1 = mrs_hw1, .hw2 = 0x8008, .npriv = true }, .{ .r0 = 0, .control = 1 }),
    vec("unprivileged mrs primask reads zero", .{ .hw1 = mrs_hw1, .hw2 = 0x8010, .npriv = true }, .{ .r0 = 0, .control = 1 }),
    vec("unprivileged mrs control reads it", .{ .hw1 = mrs_hw1, .hw2 = 0x8014, .npriv = true }, .{ .r0 = 1, .control = 1 }),
    vec("unprivileged mrs apsr reads the flags", .{ .hw1 = mrs_hw1, .hw2 = 0x8000, .npriv = true }, .{ .r0 = seed.apsr, .control = 1 }),
    vec("unprivileged mrs msp_ns reads zero", .{ .hw1 = mrs_hw1, .hw2 = 0x8088, .npriv = true }, .{ .r0 = 0, .control = 1 }),
    vec("mrs into r12 leaves r0", .{ .hw1 = mrs_hw1, .hw2 = 0x8C00 }, .{ .r12 = seed.apsr }),
};

const writes = [_]V{
    vec("msr apsr_nzcvq keeps GE", msr(0, 2, 0x5000_0000), .{ .apsr = 0x5007_0000 }),
    vec("msr apsr_g keeps the flags", msr(0, 1, 0x000C_0000), .{ .apsr = 0xA80C_0000 }),
    vec("msr apsr_nzcvqg writes both", msr(0, 3, 0xF80F_FFFF), .{ .apsr = 0xF80F_0000 }),
    vec("msr eapsr_nzcvq writes the flags", msr(2, 2, 0), .{ .apsr = 0x0007_0000 }),
    vec("msr ipsr writes nothing", msr(5, 2, 0), .{}),
    vec("msr msp", msr(8, 2, 0x2000_2000), .{ .msp = 0x2000_2000 }),
    vec("msr psp", msr(9, 2, 0x2000_3000), .{ .psp = 0x2000_3000 }),
    vec("msr msplim drops bits 2:0", msr(10, 2, 0x2000_0107), .{ .msplim = 0x2000_0100 }),
    vec("msr primask clears it", msr(16, 2, 0), .{ .primask = 0 }),
    vec("msr basepri", msr(17, 2, 0x80), .{ .basepri = 0x80 }),
    vec("msr basepri_max raises the mask", msr(18, 2, 0x20), .{ .basepri = 0x20 }),
    vec("msr basepri_max will not lower it", msr(18, 2, 0x60), .{}),
    vec("msr basepri_max of zero is ignored", msr(18, 2, 0), .{}),
    vec("msr faultmask sets it in Thread mode", msr(19, 2, 1), .{ .faultmask = 1 }),
    vec("msr faultmask cannot set it in HardFault", .{ .hw1 = msr_hw1, .hw2 = 0x8813, .ipsr = 3, .rs = 1 }, .{}),
    vec("msr control sets nPRIV and SPSEL", msr(20, 2, 3), .{ .control = 3 }),
    vec("msr control keeps SPSEL in Handler mode", .{ .hw1 = msr_hw1, .hw2 = 0x8814, .ipsr = 11, .rs = 3 }, .{ .control = 1 }),
    vec("msr control cannot write SFPA", msr(20, 2, 0x0C), .{ .control = 4 }),
    vec("msr msp_ns from Secure drops bits 1:0", msr(0x88, 2, 0x3000_1003), .{ .ns_msp = 0x3000_1000 }),
    vec("unprivileged msr msp is ignored", .{ .hw1 = msr_hw1, .hw2 = 0x8808, .npriv = true, .rs = 0x2000_2000 }, .{ .control = 1 }),
    vec("unprivileged msr primask is ignored", .{ .hw1 = msr_hw1, .hw2 = 0x8810, .npriv = true }, .{ .control = 1 }),
    vec("unprivileged msr msp_ns is ignored", .{ .hw1 = msr_hw1, .hw2 = 0x8888, .npriv = true, .rs = 4 }, .{ .control = 1 }),
    vec("unprivileged msr apsr writes the flags", .{ .hw1 = msr_hw1, .hw2 = 0x8800, .npriv = true }, .{ .apsr = 0x0007_0000, .control = 1 }),
};

const unclaimed = [_]V{
    bad("mrs into sp is unclaimed", mrs_hw1, 0x8D00),
    bad("mrs into pc is unclaimed", mrs_hw1, 0x8F00),
    bad("the reserved xPSR SYSm 4 is unclaimed", mrs_hw1, 0x8004),
    bad("an unmodelled SYSm 12 is unclaimed", mrs_hw1, 0x800C),
    bad("an unmodelled SYSm 0x30 is unclaimed", mrs_hw1, 0x8030),
    bad("mrs with hw2 bit 12 set is unclaimed", mrs_hw1, 0x9000),
    bad("msr from sp is unclaimed", 0xF38D, 0x8808),
    bad("msr from pc is unclaimed", 0xF38F, 0x8808),
    bad("msr with mask 00 is unclaimed", msr_hw1, 0x8000),
    bad("msr msp with mask 01 is unclaimed", msr_hw1, 0x8408),
    bad("msr msp with mask 11 is unclaimed", msr_hw1, 0x8C08),
    bad("msr with hw2 bit 8 set is unclaimed", msr_hw1, 0x8908),
    bad("msr with hw2 bit 13 set is unclaimed", msr_hw1, 0xA808),
    bad("hw1 F391 is unclaimed", 0xF391, 0x8808),
    vec("the 16-bit space is unclaimed", .{ .hw1 = mrs_hw1, .hw2 = 0x8000, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
