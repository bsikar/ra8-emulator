//! What one Thumb instruction of a polled trip does, in the terms a counted
//! trip needs (RA8EMU-602): which register it writes and from what, which
//! memory it touches through which base, and whether it sets or reads the
//! flags. Only the forms bounded polls are built from are named; anything
//! else is `unknown`, and a trip holding one is never counted. An IT
//! instruction is unknown too, which matters: inside an IT block the narrow
//! data-processing forms leave the flags alone, and this table assumes they
//! set them.
const thumb_imm = @import("thumb_imm.zig");

pub const Form = enum {
    unknown,
    /// rd = rm, or rd = imm when rm is null.
    move,
    /// rd = rn + (rm or imm), and rd = rn - (rm or imm).
    add,
    sub,
    /// rd = [rn + imm] and [rn + imm] = rd, `size` bytes. Rn 15 is a literal.
    load,
    store,
    /// The flags of rn - (rm or imm).
    compare,
    /// rd (when not null) is a function of rn and rm the trip cannot follow.
    opaque_alu,
    branch,
    cond_branch,
    /// CBZ and CBNZ, which test rn.
    cbz,
    call,
    /// BX rm.
    bx,
    /// The register list is in imm, LR as bit 14 and PC as bit 15.
    push,
    pop,
    /// NOP and CPSIE/CPSID i.
    hint,
};

pub const Step = struct {
    form: Form = .unknown,
    len: u3 = 2,
    rd: ?u4 = null,
    rn: ?u4 = null,
    rm: ?u4 = null,
    imm: u32 = 0,
    size: u3 = 4,
    sets_flags: bool = false,
    reads_flags: bool = false,
    /// A load or store whose address is rn alone, with rn moved by imm after
    /// (post-index), or rn + imm with rn left there (pre-index writeback).
    writeback: bool = false,
    post_index: bool = false,
};

/// A 32-bit encoding starts 0b11101, 0b11110 or 0b11111.
pub fn wide(hw1: u16) bool {
    return hw1 >> 11 >= 0x1D;
}

pub fn decode(hw1: u16, hw2: u16) Step {
    if (wide(hw1)) {
        var step = decodeWide(hw1, hw2);
        step.len = 4;
        return step;
    }
    return decodeNarrow(hw1);
}

fn reg(value: u16) u4 {
    return @intCast(value & 0xF);
}

fn lo(value: u16) u4 {
    return @intCast(value & 0x7);
}

fn mem(form: Form, rt: u4, rn: u4, imm: u32, size: u3) Step {
    return .{ .form = form, .rd = rt, .rn = rn, .imm = imm, .size = size };
}

fn arith(form: Form, rd: u4, rn: u4, rm: ?u4, imm: u32, sets: bool) Step {
    return .{ .form = form, .rd = rd, .rn = rn, .rm = rm, .imm = imm, .sets_flags = sets };
}

fn decodeNarrow(hw: u16) Step {
    const r0 = lo(hw);
    const r3 = lo(hw >> 3);
    const r6 = lo(hw >> 6);
    const r8 = lo(hw >> 8);
    const imm8: u32 = hw & 0xFF;
    const imm5: u32 = (hw >> 6) & 0x1F;
    const high_rd: u4 = @intCast(((hw >> 4) & 0x8) | (hw & 0x7));
    return switch (hw & 0xF800) {
        0x6800 => mem(.load, r0, r3, imm5 * 4, 4),
        0x6000 => mem(.store, r0, r3, imm5 * 4, 4),
        0x7800 => mem(.load, r0, r3, imm5, 1),
        0x7000 => mem(.store, r0, r3, imm5, 1),
        0x8800 => mem(.load, r0, r3, imm5 * 2, 2),
        0x8000 => mem(.store, r0, r3, imm5 * 2, 2),
        0x9800 => mem(.load, r8, 13, imm8 * 4, 4),
        0x9000 => mem(.store, r8, 13, imm8 * 4, 4),
        0x4800 => mem(.load, r8, 15, imm8 * 4, 4),
        0x2000 => .{ .form = .move, .rd = r8, .imm = imm8, .sets_flags = true },
        0x2800 => .{ .form = .compare, .rn = r8, .imm = imm8, .sets_flags = true },
        0x3000 => arith(.add, r8, r8, null, imm8, true),
        0x3800 => arith(.sub, r8, r8, null, imm8, true),
        0xA800 => arith(.add, r8, 13, null, imm8 * 4, false),
        0xE000 => .{ .form = .branch },
        else => switch (hw & 0xFE00) {
            0x1C00 => arith(.add, r0, r3, null, r6, true),
            0x1E00 => arith(.sub, r0, r3, null, r6, true),
            0x1800 => arith(.add, r0, r3, r6, 0, true),
            0x1A00 => arith(.sub, r0, r3, r6, 0, true),
            0xB400 => .{ .form = .push, .imm = (hw & 0xFF) | @as(u32, (hw >> 8) & 1) << 14 },
            0xBC00 => .{ .form = .pop, .imm = (hw & 0xFF) | @as(u32, (hw >> 8) & 1) << 15 },
            else => narrowRest(hw, r0, r3, high_rd),
        },
    };
}

fn narrowRest(hw: u16, r0: u4, r3: u4, high_rd: u4) Step {
    const rm4 = reg(hw >> 3);
    if (hw & 0xFFC0 == 0x0000) return .{ .form = .move, .rd = r0, .rm = r3, .sets_flags = true };
    if (hw & 0xFFC0 == 0x4280) return .{ .form = .compare, .rn = r0, .rm = r3, .sets_flags = true };
    if (hw & 0xFFC0 == 0x4000) return arith(.opaque_alu, r0, r0, r3, 0, true);
    if (hw & 0xFFC0 == 0x4200) return .{ .form = .opaque_alu, .rn = r0, .rm = r3, .sets_flags = true };
    if (hw & 0xFF00 == 0x4500) return .{ .form = .compare, .rn = high_rd, .rm = rm4, .sets_flags = true };
    if (hw & 0xFF00 == 0x4600) return .{ .form = .move, .rd = high_rd, .rm = rm4 };
    if (hw & 0xFF87 == 0x4700) return .{ .form = .bx, .rm = rm4 };
    if (hw & 0xFF80 == 0xB000) return arith(.add, 13, 13, null, (hw & 0x7F) * 4, false);
    if (hw & 0xFF80 == 0xB080) return arith(.sub, 13, 13, null, (hw & 0x7F) * 4, false);
    if (hw & 0xF500 == 0xB100) return .{ .form = .cbz, .rn = r0 };
    if (hw == 0xBF00 or hw & 0xFFEF == 0xB662) return .{ .form = .hint };
    if (hw & 0xF000 == 0xD000 and (hw >> 8) & 0xF < 0xE) return .{ .form = .cond_branch, .reads_flags = true };
    return .{};
}

/// ThumbExpandImm over i:imm3:imm8; null for an UNPREDICTABLE pattern.
fn modified(hw1: u16, hw2: u16) ?u32 {
    const imm: u12 = @intCast(((hw1 >> 10) & 1) << 11 | ((hw2 >> 12) & 7) << 8 | (hw2 & 0xFF));
    const shifted = thumb_imm.expandC(imm, false) orelse return null;
    return shifted.result;
}

/// The plain 12-bit immediate of ADDW and SUBW.
fn plain12(hw1: u16, hw2: u16) u32 {
    return @as(u32, (hw1 >> 10) & 1) << 11 | @as(u32, (hw2 >> 12) & 7) << 8 | (hw2 & 0xFF);
}

fn decodeWide(hw1: u16, hw2: u16) Step {
    const rn = reg(hw1);
    const rt = reg(hw2 >> 12);
    const rd = reg(hw2 >> 8);
    const sets = hw1 & 0x10 != 0;
    if (hw1 & 0xF800 == 0xF000 and hw2 & 0x8000 != 0) return branches(hw1, hw2);
    if (hw1 & 0xFFF0 == 0xF8D0) return mem(.load, rt, rn, hw2 & 0xFFF, 4);
    if (hw1 & 0xFFF0 == 0xF8C0) return mem(.store, rt, rn, hw2 & 0xFFF, 4);
    if (hw1 & 0xFFE0 == 0xF840 and hw2 & 0x0800 != 0 and rn != 15) return indexed(hw1, hw2);
    if (hw2 & 0x8000 != 0) return .{};
    switch (hw1 & 0xFBE0) {
        0xF000 => return .{ .form = .opaque_alu, .rd = if (rd == 15) null else rd, .rn = rn, .sets_flags = sets },
        0xF100, 0xF1A0 => {
            const imm = modified(hw1, hw2) orelse return .{};
            if (rd == 15) {
                if (hw1 & 0xFBF0 != 0xF1B0) return .{};
                return .{ .form = .compare, .rn = rn, .imm = imm, .sets_flags = true };
            }
            return arith(if (hw1 & 0xFBE0 == 0xF100) .add else .sub, rd, rn, null, imm, sets);
        },
        0xF040 => {
            if (rn != 15) return .{};
            const imm = modified(hw1, hw2) orelse return .{};
            return .{ .form = .move, .rd = rd, .imm = imm, .sets_flags = sets };
        },
        else => {},
    }
    return switch (hw1 & 0xFBF0) {
        0xF200 => arith(.add, rd, rn, null, plain12(hw1, hw2), false),
        0xF2A0 => arith(.sub, rd, rn, null, plain12(hw1, hw2), false),
        0xF240 => .{ .form = .move, .rd = rd, .imm = @as(u32, rn) << 12 | plain12(hw1, hw2) },
        else => .{},
    };
}

/// BL, B.W and B<c>.W; the rest of the hw2 bit 15 space is control.
fn branches(hw1: u16, hw2: u16) Step {
    switch (hw2 & 0xD000) {
        0xD000 => return .{ .form = .call },
        0x9000 => return .{ .form = .branch },
        0x8000 => {
            if ((hw1 >> 6) & 0xF >= 0xE) return .{};
            return .{ .form = .cond_branch, .reads_flags = true };
        },
        else => return .{},
    }
}

/// LDR and STR (immediate, T4): post-index, or pre-index with writeback.
/// Plain negative offsets and the unprivileged forms stay unknown.
fn indexed(hw1: u16, hw2: u16) Step {
    const index = hw2 & 0x0400 != 0;
    const back = hw2 & 0x0100 != 0;
    if (!back) return .{};
    const magnitude: u32 = hw2 & 0xFF;
    const offset = if (hw2 & 0x0200 != 0) magnitude else 0 -% magnitude;
    const form: Form = if (hw1 & 0x0010 != 0) .load else .store;
    var step = mem(form, reg(hw2 >> 12), reg(hw1), offset, 4);
    step.writeback = true;
    step.post_index = !index;
    return step;
}
