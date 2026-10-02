//! Load-acquire and store-release without the monitor (RA8EMU-131): LDA,
//! LDAB, LDAH, STL, STLB and STLH (T1, hw1 = 1110 1000 110 L Rn, hw2 = Rt
//! 1111 10 sz 1111). The address is Rn with no offset.
//!
//! Acquire and release order this access against other observers. One core
//! stepping in program order already gives that, so the ordering is a no-op
//! here. Every form is MemA: an unaligned one is a UsageFault.UNALIGNED.
//! The exclusive forms (LDAEX, STLEX and their narrow variants) share the
//! monitor and live in exclusive.zig.
//!
//! Left unclaimed: SP or PC as Rt, and PC as Rn.
const std = @import("std");
const op = @import("../op.zig");
const alignment = @import("../alignment.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const rn_mask: u16 = 0xFFF0;
    pub const load: u16 = 0xE8D0;
    pub const store: u16 = 0xE8C0;
    /// hw2 with Rt and sz ([5:4]) masked out: 1111 10 sz 1111.
    pub const hw2_mask: u16 = 0x0FCF;
    pub const hw2_match: u16 = 0x0F8F;
};

pub const group: op.Group = .{ .name = "acq_rel", .decode = decode };

pub const Access = struct {
    load: bool,
    /// Bytes moved: 1, 2 or 4.
    size: u3,
    rt: u4,
    rn: u4,
};

pub fn access(instr: Instr) ?Access {
    const e = encodings;
    if (instr.size != 4) return null;
    const kind = instr.hw1 & e.rn_mask;
    if (kind != e.load and kind != e.store) return null;
    if (instr.hw2 & e.hw2_mask != e.hw2_match) return null;
    const size: u3 = switch ((instr.hw2 >> 4) & 0x3) {
        0 => 1,
        1 => 2,
        2 => 4,
        else => return null,
    };
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rt: u4 = @intCast(instr.hw2 >> 12);
    if (rn == 15 or rt == 13 or rt == 15) return null;
    return .{ .load = kind == e.load, .size = size, .rt = rt, .rn = rn };
}

fn decode(instr: Instr) ?op.Exec {
    const a = access(instr) orelse return null;
    return if (a.load) loadAcquire else storeRelease;
}

fn loadAcquire(cpu: *Cpu, instr: Instr) op.Error!void {
    const a = access(instr).?;
    const address = cpu.regs.get(a.rn);
    try alignment.memA(address, a.size);
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    try cpu.bus.read(address, bytes[0..a.size]);
    cpu.regs.set(a.rt, std.mem.readInt(u32, &bytes, .little));
}

fn storeRelease(cpu: *Cpu, instr: Instr) op.Error!void {
    const a = access(instr).?;
    const address = cpu.regs.get(a.rn);
    try alignment.memA(address, a.size);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, cpu.regs.get(a.rt), .little);
    try cpu.bus.write(address, bytes[0..a.size]);
}
