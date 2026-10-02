//! MVE VMOV between a general-purpose register and one vector lane
//! (RA8EMU-25): VMOV.<size> Qd[x], Rt and VMOV.<dt> Rt, Qn[x]. The Arm ARM
//! (DDI0553) encodes the lane as the scalar Dd[x] of the D register that
//! holds it, with opc1:opc2 giving size and index: 1xxx byte, 0xx1 half,
//! 0x00 word. Reading a byte or half sign-extends unless U is set; U with a
//! word is undefined. Per QEMU's mve_skip_vmov these moves are not
//! predicated and do not advance a VPT block (they are only subject to
//! beat-wise execution, which waits on ECI). D or N set would name D16+,
//! which MVE lacks, and Rt of 13 or 15 is UNPREDICTABLE, so all of those
//! stay unclaimed.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;
const mve = @import("../mve/all.zig");
const Size = mve.qreg.Size;

pub const group: op.Group = .{ .name = "mve_lane_move", .decode = decode, .oracle = false };

pub const encodings = struct {
    pub const to_lane_hw1_mask: u16 = 0xFF90;
    pub const to_lane_hw1: u16 = 0xEE00;
    pub const to_core_hw1_mask: u16 = 0xFF10;
    pub const to_core_hw1: u16 = 0xEE10;
    /// Rt, D/N and opc2 masked out.
    pub const hw2_mask: u16 = 0x0F1F;
    pub const hw2: u16 = 0x0B10;
};

/// Which Q register and which element of it a scalar Dd[x] names.
pub const Lane = struct { size: Size, q: u3, elem: u8 };

/// Decodes opc1:opc2 and the D register into a lane, or null when undefined.
pub fn laneOf(instr: Instr) ?Lane {
    const opc1: u8 = @intCast(instr.hw1 >> 5 & 3);
    const opc2: u8 = @intCast(instr.hw2 >> 5 & 3);
    const d: u8 = @intCast(instr.hw1 & 0xF);
    const size: Size, const index: u8 = if (opc1 & 2 != 0)
        .{ .byte, (opc1 & 1) << 2 | opc2 }
    else if (opc2 & 1 != 0)
        .{ .half, (opc1 & 1) << 1 | opc2 >> 1 }
    else if (opc2 == 0)
        .{ .word, opc1 & 1 }
    else
        return null;
    const per_d = mve.qreg.lanes(size) / 2;
    return .{ .size = size, .q = @intCast(d >> 1), .elem = (d & 1) * per_d + index };
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size != 4 or instr.hw2 & encodings.hw2_mask != encodings.hw2) return null;
    if (instr.hw2 >> 7 & 1 == 1) return null;
    const rt = instr.hw2 >> 12;
    if (rt == 13 or rt == 15) return null;
    const lane = laneOf(instr) orelse return null;
    if (instr.hw1 & encodings.to_lane_hw1_mask == encodings.to_lane_hw1) return toLane;
    if (instr.hw1 & encodings.to_core_hw1_mask != encodings.to_core_hw1) return null;
    const unsigned = instr.hw1 >> 7 & 1 == 1;
    if (unsigned and lane.size == .word) return null;
    return if (unsigned) toCoreFor(false) else toCoreFor(true);
}

fn toLane(cpu: *Cpu, instr: Instr) op.Error!void {
    const lane = laneOf(instr).?;
    const bank = &cpu.fp.bank;
    const old = mve.qreg.read(bank, lane.q);
    const rt = cpu.regs.get(@intCast(instr.hw2 >> 12));
    mve.qreg.write(bank, lane.q, mve.qreg.setElem(old, lane.size, lane.elem, rt));
}

fn toCoreFor(comptime signed: bool) op.Exec {
    return struct {
        fn exec(cpu: *Cpu, instr: Instr) op.Error!void {
            const lane = laneOf(instr).?;
            const raw = mve.qreg.elem(mve.qreg.read(&cpu.fp.bank, lane.q), lane.size, lane.elem);
            cpu.regs.set(@intCast(instr.hw2 >> 12), if (signed) extend(raw, lane.size) else raw);
        }
    }.exec;
}

fn extend(raw: u32, size: Size) u32 {
    return switch (size) {
        .byte => @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(raw)))))),
        .half => @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(raw)))))),
        .word => raw,
    };
}
