//! One backend's architectural state after an instruction. Both backends are
//! read into the same shape, register by register in `compared` order, so the
//! lockstep harness diffs them one name at a time.
//!
//! SP is left out on purpose. It is whichever of MSP and PSP the mode selects,
//! and both banked pointers are compared directly, so a stack divergence is
//! reported once, under the pointer that actually moved.
const regs = @import("../regs.zig");

pub const compared = [_]regs.Name{
    .r0,  .r1,   .r2,      .r3,      .r4,      .r5,        .r6, .r7,
    .r8,  .r9,   .r10,     .r11,     .r12,     .lr,        .pc, .msp,
    .psp, .xpsr, .control, .primask, .basepri, .faultmask,
};

pub const Snapshot = struct {
    values: [compared.len]u32,

    /// The Zig core's side.
    pub fn fromRegs(file: *const regs.Regs) Snapshot {
        var values: [compared.len]u32 = undefined;
        for (compared, 0..) |name, i| values[i] = file.read(name);
        return .{ .values = values };
    }

    /// Where `name` sits in `values`, or null for a register this snapshot
    /// does not hold (SP).
    pub fn index(name: regs.Name) ?usize {
        for (compared, 0..) |candidate, i| {
            if (candidate == name) return i;
        }
        return null;
    }

    pub fn get(self: Snapshot, name: regs.Name) ?u32 {
        const i = index(name) orelse return null;
        return self.values[i];
    }
};
