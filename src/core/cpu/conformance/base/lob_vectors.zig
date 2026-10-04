//! Conformance vectors for the decode group `lob` (RA8EMU-278): DLS, WLS
//! and LE (T1), Armv8.1-M low-overhead loops. Expected values are worked
//! from the Arm ARM (DDI0553): DLS loads LR from Rn and falls through; WLS
//! does the same on a non-zero count and branches forward by
//! imm10:immL:'0' on zero, leaving LR; LE with LR above one decrements it
//! and branches back by the same field, with LR one it writes zero and
//! falls through, and with LR zero it falls through untouched. LE takes an
//! INVSTATE UsageFault with nothing changed when an FP context is active
//! (CONTROL.FPCA) and FPSCR.LTPSIZE is not 4; with no FP context LTPSIZE
//! reads 4. None of them touches the flags. SP or PC as the DLS/WLS
//! source, the tail-predicated DLSTP/WLSTP/LETP and LCTP (MVE, RA8EMU-24),
//! other second halfwords and the 16-bit space are left unclaimed.
const vector = @import("../vector.zig");

/// The instruction sits at `pc_in`; the next one is at `after`.
pub const pc_in: u32 = 0x2000_0100;
const after: u32 = pc_in + 4;
pub const lr_in: u32 = 0x1000_000E;
/// Thumb with N, Z, C, V and Q set.
pub const xpsr_in: u32 = 0x0100_0000 | 0xF800_0000;

pub const In = struct {
    hw1: u16,
    hw2: u16,
    size: u8 = 4,
    /// The source register's value (R0, or R12 when hw1 names it).
    rn: u32 = 0,
    lr: u32 = lr_in,
    /// CONTROL.FPCA, and FPSCR.LTPSIZE.
    fpca: bool = false,
    ltpsize: u3 = 4,
};

/// How the instruction ended.
pub const Fault = enum { none, invalid_state, other };

/// Whether the group claims the encoding, how it ended, and PC, LR and
/// xPSR after.
pub const Out = struct {
    claimed: bool = true,
    fault: Fault = .none,
    pc: u32 = after,
    lr: u32 = lr_in,
    xpsr: u32 = xpsr_in,
};

const V = vector.Vector(In, Out);
const group = "lob";
pub const none: Out = .{ .claimed = false, .pc = 0, .lr = 0, .xpsr = 0 };

fn vec(name: []const u8, input: In, expect: Out) V {
    return .{ .encoding = group, .name = name, .input = input, .expect = expect };
}

fn bad(name: []const u8, hw1: u16, hw2: u16) V {
    return vec(name, .{ .hw1 = hw1, .hw2 = hw2 }, none);
}

/// imm10:immL:'0' = 8, 6 and 0xFFE bytes.
const by8: u16 = 0xC005;
const by6: u16 = 0xC803;
const by_max: u16 = 0xCFFF;

pub const all = dls ++ wls ++ le ++ unclaimed;

const dls = [_]V{
    vec("dls lr, r0 loads the count", .{ .hw1 = 0xF040, .hw2 = 0xE001, .rn = 5 }, .{ .lr = 5 }),
    vec("dls lr, r0 with zero still falls through", .{ .hw1 = 0xF040, .hw2 = 0xE001, .rn = 0 }, .{ .lr = 0 }),
    vec("dls lr, r12", .{ .hw1 = 0xF04C, .hw2 = 0xE001, .rn = 7 }, .{ .lr = 7 }),
    vec("dls lr, lr keeps lr", .{ .hw1 = 0xF04E, .hw2 = 0xE001 }, .{}),
    vec("dls lr, r0 with a full count", .{ .hw1 = 0xF040, .hw2 = 0xE001, .rn = 0xFFFF_FFFF }, .{ .lr = 0xFFFF_FFFF }),
};

const wls = [_]V{
    vec("wls lr, r0 with a count falls through", .{ .hw1 = 0xF040, .hw2 = by8, .rn = 3 }, .{ .lr = 3 }),
    vec("wls lr, r0 with zero skips 8 bytes", .{ .hw1 = 0xF040, .hw2 = by8, .rn = 0 }, .{ .pc = after + 8 }),
    vec("wls with immL set skips 6 bytes", .{ .hw1 = 0xF040, .hw2 = by6, .rn = 0 }, .{ .pc = after + 6 }),
    vec("wls with the widest field skips 0xFFE bytes", .{ .hw1 = 0xF040, .hw2 = by_max, .rn = 0 }, .{ .pc = after + 0xFFE }),
    vec("wls lr, r12 with a count", .{ .hw1 = 0xF04C, .hw2 = by8, .rn = 1 }, .{ .lr = 1 }),
    vec("wls lr, lr with zero lr skips", .{ .hw1 = 0xF04E, .hw2 = by8, .lr = 0 }, .{ .pc = after + 8, .lr = 0 }),
};

const le = [_]V{
    vec("le with lr 3 decrements and branches back", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 3 }, .{ .pc = after - 8, .lr = 2 }),
    vec("le with lr 2 branches once more", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 2 }, .{ .pc = after - 8, .lr = 1 }),
    vec("le with lr 1 writes zero and falls through", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 1 }, .{ .lr = 0 }),
    vec("le with lr 0 falls through untouched", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 0 }, .{ .lr = 0 }),
    vec("le with a full lr branches", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 0xFFFF_FFFF }, .{ .pc = after - 8, .lr = 0xFFFF_FFFE }),
    vec("le with immL set branches back 6", .{ .hw1 = 0xF00F, .hw2 = by6, .lr = 9 }, .{ .pc = after - 6, .lr = 8 }),
    vec("le with the widest field branches back 0xFFE", .{ .hw1 = 0xF00F, .hw2 = by_max, .lr = 4 }, .{ .pc = after -% 0xFFE, .lr = 3 }),
    vec("le with an fp context and ltpsize 4 runs", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 3, .fpca = true }, .{ .pc = after - 8, .lr = 2 }),
    vec("le with an fp context and ltpsize 2 faults", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 3, .fpca = true, .ltpsize = 2 }, .{ .fault = .invalid_state, .pc = pc_in, .lr = 3 }),
    vec("le with an fp context and ltpsize 0 faults", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 3, .fpca = true, .ltpsize = 0 }, .{ .fault = .invalid_state, .pc = pc_in, .lr = 3 }),
    vec("le with no fp context ignores ltpsize", .{ .hw1 = 0xF00F, .hw2 = by8, .lr = 3, .ltpsize = 2 }, .{ .pc = after - 8, .lr = 2 }),
};

const unclaimed = [_]V{
    bad("dls lr, sp is unclaimed", 0xF04D, 0xE001),
    bad("dls lr, pc is unclaimed", 0xF04F, 0xE001),
    bad("wls lr, sp is unclaimed", 0xF04D, by8),
    bad("wls lr, pc is unclaimed", 0xF04F, by8),
    bad("dls with hw2 0xE003 is unclaimed", 0xF040, 0xE003),
    bad("hw2[15:12] = 1101 is unclaimed", 0xF040, 0xD005),
    bad("letp is unclaimed", 0xF01F, by8),
    bad("dlstp is unclaimed", 0xF020, 0xE001),
    bad("wlstp is unclaimed", 0xF020, by8),
    bad("lctp is unclaimed", 0xF00F, 0xE001),
    bad("hw1 0xF00E is unclaimed", 0xF00E, by8),
    vec("the 16-bit space is unclaimed", .{ .hw1 = 0xF040, .hw2 = 0xE001, .size = 2 }, none),
};

pub const covered = vector.encodingsOf(In, Out, &all);
