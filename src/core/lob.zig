//! Armv8.1-M low-overhead loops: DLS, WLS and LE.
//!
//! The RA8D2 core is a Cortex-M85, and a compiler told to target one emits
//! these three instructions for an ordinary counted loop, `memcpy` and
//! `memset` included. The pinned Unicorn offers no Armv8.1-M CPU model: the
//! newest it has is the Cortex-M33, which is Armv8.0-M, so the core rejects
//! the encoding and a real image stops in its C startup before it reaches
//! main(). They are decoded and stepped here instead, off the
//! invalid-instruction hook, which is cheaper and far more honest than
//! telling a compiler not to emit them.
//!
//! LETP and the rest of the tail-predicated family belong to MVE and are
//! deliberately absent: predication changes how the loop body executes, not
//! just how it counts, so stepping the counter alone would run the body wrong
//! and look like it worked.
const std = @import("std");

pub const Kind = enum { dls, wls, le };

pub const Instruction = struct {
    kind: Kind,
    /// Rn for DLS and WLS. LE reads LR and leaves this zero.
    source: u4 = 0,
    /// Branch distance in bytes: forward for WLS, backward for LE.
    offset: u32 = 0,
};

/// The encoding, grouped rather than left loose so the decoder below reads as
/// the thing it implements.
pub const encoding = struct {
    /// Both halfwords, so a caller knows how far to step past one.
    pub const width: u32 = 4;
    /// DLS and WLS share a first halfword: 0xF04n, with n the source register.
    pub const setup_mask: u16 = 0xFFF0;
    pub const setup: u16 = 0xF040;
    pub const source_mask: u16 = 0x000F;
    /// LE has no source register, so its Rn field reads as 0xF.
    pub const le_first: u16 = 0xF00F;
    /// LETP, the MVE tail-predicated loop end. Named to be refused, not run.
    pub const letp_first: u16 = 0xF01F;
    /// The second halfword tells the two apart: 0xE001 sets a counter and
    /// stays put, 0xCxxx carries a branch.
    pub const dls_second: u16 = 0xE001;
    pub const branch_mask: u16 = 0xF000;
    pub const branch: u16 = 0xC000;
    /// The branch distance sits in bits [10:1], already scaled by two, with
    /// bit 11 as the halfword LSB. Doubling that count gives bytes.
    pub const distance_mask: u16 = 0x07FE;
    pub const distance_lsb: u4 = 11;
};

/// The instruction at a PC, or null when those four bytes are something else.
/// Null is the important answer: it leaves a genuine undefined encoding a
/// fault, rather than quietly stepping over it.
pub fn decode(first: u16, second: u16) ?Instruction {
    if (second & encoding.branch_mask == encoding.branch) {
        const distance = branchDistance(second);
        if (first == encoding.le_first) return .{ .kind = .le, .offset = distance };
        if (first & encoding.setup_mask == encoding.setup) return .{
            .kind = .wls,
            .source = @truncate(first & encoding.source_mask),
            .offset = distance,
        };
        return null;
    }
    if (second == encoding.dls_second and first & encoding.setup_mask == encoding.setup) {
        return .{ .kind = .dls, .source = @truncate(first & encoding.source_mask) };
    }
    return null;
}

fn branchDistance(second: u16) u32 {
    const halfwords: u32 = (second & encoding.distance_mask) |
        ((second >> encoding.distance_lsb) & 1);
    return halfwords * 2;
}

/// What one of these does to the machine: where the core goes next, and the
/// loop counter when it changes. A null `lr` means the instruction left the
/// counter alone, which is not the same as writing it back unchanged.
pub const Step = struct {
    next_pc: u32,
    lr: ?u32 = null,
};

pub fn step(instruction: Instruction, pc: u32, source: u32, lr: u32) Step {
    const after = pc +% encoding.width;
    return switch (instruction.kind) {
        // DLS loads the counter and falls through: the loop always runs once.
        .dls => .{ .next_pc = after, .lr = source },
        // WLS is DLS with the zero-trip case: a count of zero skips the body
        // entirely rather than wrapping to four billion iterations.
        .wls => if (source == 0)
            .{ .next_pc = after +% instruction.offset }
        else
            .{ .next_pc = after, .lr = source },
        // LE decrements first and branches only on a non-zero result, which
        // is what makes `DLS LR, Rn` run the body exactly Rn times: the last
        // iteration has already executed by the time the counter reaches
        // zero. Decrementing after the branch test instead runs the body once
        // too often, and against a memcpy that is a silent overrun rather
        // than a fault. LR at zero on entry falls through untouched rather
        // than wrapping to four billion.
        .le => if (lr == 0)
            .{ .next_pc = after }
        else if (lr == 1)
            .{ .next_pc = after, .lr = 0 }
        else
            .{ .next_pc = after -% instruction.offset, .lr = lr - 1 },
    };
}

/// How often the run needed this. Reported at the end so a run that leans on
/// the hook says so, instead of the CPU model's gap passing unnoticed.
pub const Loops = struct {
    stepped: usize = 0,

    pub fn quiet(self: Loops) bool {
        return self.stepped == 0;
    }
};
