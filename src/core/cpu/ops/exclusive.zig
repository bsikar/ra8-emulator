//! The exclusive accesses and the local monitor: LDREX, LDREXB, LDREXH (T1),
//! STREX, STREXB, STREXH (T1) and CLREX.
//!
//! The monitor is one tagged address in `Cpu.exclusive`. A load-exclusive
//! sets it, CLREX and exception entry or return clear it, and a
//! store-exclusive writes only when it is set to the store's address, puts 0
//! (stored) or 1 (not stored) in Rd, and clears it either way.
//!
//! Left unclaimed: SP or PC as Rt or Rd, PC as Rn, and a store whose Rd
//! repeats Rt or Rn. Alignment faults belong to RA8EMU-85.
const op = @import("../op.zig");
const Cpu = @import("../cpu.zig").Cpu;
const Instr = @import("../instr.zig").Instr;

pub const encodings = struct {
    pub const rn_mask: u16 = 0xFFF0;
    pub const ldrex: u16 = 0xE850;
    pub const strex: u16 = 0xE840;
    /// LDREXB/H and STREXB/H, picked by hw2[7:4].
    pub const ldrex_narrow: u16 = 0xE8D0;
    pub const strex_narrow: u16 = 0xE8C0;
    pub const clrex_hw1: u16 = 0xF3BF;
    pub const clrex_hw2: u16 = 0x8F2F;
};

pub const group: op.Group = .{ .name = "exclusive", .decode = decode };

pub const Access = struct {
    load: bool,
    size: u3,
    rt: u4,
    rn: u4,
    /// Status register for a store; unused for a load.
    rd: u4 = 0,
    offset: u32 = 0,
};

fn bad(r: u4) bool {
    return r == 13 or r == 15;
}

fn narrowSize(op3: u16) ?u3 {
    return switch (op3) {
        0x4 => 1,
        0x5 => 2,
        else => null,
    };
}

pub fn access(instr: Instr) ?Access {
    if (instr.size != 4) return null;
    const rn: u4 = @intCast(instr.hw1 & 0xF);
    const rt: u4 = @intCast(instr.hw2 >> 12);
    const nibble: u4 = @intCast((instr.hw2 >> 8) & 0xF);
    const a: Access = switch (instr.hw1 & encodings.rn_mask) {
        encodings.ldrex => if (nibble != 0xF) return null else .{ .load = true, .size = 4, .rt = rt, .rn = rn, .offset = @as(u32, instr.hw2 & 0xFF) << 2 },
        encodings.strex => .{ .load = false, .size = 4, .rt = rt, .rn = rn, .rd = nibble, .offset = @as(u32, instr.hw2 & 0xFF) << 2 },
        encodings.ldrex_narrow => blk: {
            if (nibble != 0xF or instr.hw2 & 0xF != 0xF) return null;
            break :blk .{ .load = true, .size = narrowSize((instr.hw2 >> 4) & 0xF) orelse return null, .rt = rt, .rn = rn };
        },
        encodings.strex_narrow => blk: {
            if (nibble != 0xF) return null;
            break :blk .{ .load = false, .size = narrowSize((instr.hw2 >> 4) & 0xF) orelse return null, .rt = rt, .rn = rn, .rd = @intCast(instr.hw2 & 0xF) };
        },
        else => return null,
    };
    if (rn == 15 or bad(a.rt)) return null;
    if (!a.load and (bad(a.rd) or a.rd == a.rt or a.rd == a.rn)) return null;
    return a;
}

fn decode(instr: Instr) ?op.Exec {
    if (instr.size == 4 and instr.hw1 == encodings.clrex_hw1 and instr.hw2 == encodings.clrex_hw2) return clrex;
    const a = access(instr) orelse return null;
    return if (a.load) load else store;
}

fn clrex(cpu: *Cpu, _: Instr) op.Error!void {
    cpu.exclusive = null;
}

fn load(cpu: *Cpu, instr: Instr) op.Error!void {
    const a = access(instr).?;
    const address = cpu.regs.get(a.rn) +% a.offset;
    var bytes: [4]u8 = .{ 0, 0, 0, 0 };
    try cpu.bus.read(address, bytes[0..a.size]);
    cpu.regs.set(a.rt, @import("std").mem.readInt(u32, &bytes, .little));
    cpu.exclusive = address;
}

fn store(cpu: *Cpu, instr: Instr) op.Error!void {
    const a = access(instr).?;
    const address = cpu.regs.get(a.rn) +% a.offset;
    const held = cpu.exclusive == address;
    cpu.exclusive = null;
    if (held) {
        var bytes: [4]u8 = undefined;
        @import("std").mem.writeInt(u32, &bytes, cpu.regs.get(a.rt), .little);
        try cpu.bus.write(address, bytes[0..a.size]);
    }
    cpu.regs.set(a.rd, if (held) 0 else 1);
}
