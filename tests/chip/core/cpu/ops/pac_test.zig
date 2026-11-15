//! Covers src/chip/core/cpu/ops/pac.zig.
const std = @import("std");
const ra8 = @import("ra8");
const qarma = ra8.chip.core.cpu.ops.qarma;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Instr = ra8.chip.core.cpu.instr.Instr;
const State = ra8.chip.core.banked.State;
const bus = ra8.chip.core.cpu.bus;
const memmap = ra8.chip.core.memmap;
const pac = ra8.chip.core.cpu.ops.pac;
const regs = ra8.chip.core.cpu.regs;

fn instr(hw1: u16, hw2: u16) Instr {
    return .{ .address = 0x100, .hw1 = hw1, .hw2 = hw2, .size = 4 };
}

fn execute(cpu: *Cpu, hw1: u16, hw2: u16) !void {
    const i = instr(hw1, hw2);
    const run = pac.group.decode(i) orelse return error.NotClaimed;
    try run(cpu, i);
}

fn enabledCpu() Cpu {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.control = regs.control_bits.pac_en;
    cpu.regs.pac_key_p = .{ 1, 2, 3, 4 };
    cpu.regs.lr = 0x0800_1235;
    cpu.regs.msp = 0x2000_1000;
    return cpu;
}

test "PAC, AUT authenticate an unchanged LR and fault on a corrupted return address" {
    var cpu = enabledCpu();
    try execute(&cpu, 0xF3AF, 0x801D); // pac r12, lr, sp
    const signed = cpu.regs.low[12];
    try std.testing.expect(signed != 0);
    try execute(&cpu, 0xF3AF, 0x802D); // aut r12, lr, sp

    cpu.regs.lr ^= 4;
    try std.testing.expectError(error.InvalidState, execute(&cpu, 0xF3AF, 0x802D));
}

const FaultBus = struct {
    code: [4]u8 = .{ 0xAF, 0xF3, 0x2D, 0x80 }, // aut r12, lr, sp
    cfsr: u32 = 0,
    shcsr: u32 = 1 << 18,

    fn withCode(hw1: u16, hw2: u16) FaultBus {
        var code: [4]u8 = undefined;
        std.mem.writeInt(u16, code[0..2], hw1, .little);
        std.mem.writeInt(u16, code[2..4], hw2, .little);
        return .{ .code = code };
    }

    fn view(self: *FaultBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *FaultBus = @ptrCast(@alignCast(ctx));
        if (address >= 0x100 and address + into.len <= 0x104) {
            @memcpy(into, self.code[address - 0x100 ..][0..into.len]);
            return;
        }
        const value = if (address == memmap.scb.cfsr) self.cfsr else if (address == memmap.scb.shcsr) self.shcsr else 0;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        if (address <= memmap.scb.cfsr and address + into.len > memmap.scb.cfsr) {
            @memcpy(into, bytes[0..into.len]);
            return;
        }
        if (address <= memmap.scb.shcsr and address + into.len > memmap.scb.shcsr) {
            @memcpy(into, bytes[0..into.len]);
            return;
        }
        if (address < 4) {
            @memset(into, 0);
            return;
        }
        return error.Unmapped;
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *FaultBus = @ptrCast(@alignCast(ctx));
        if (address == memmap.scb.cfsr and from.len == 4) {
            self.cfsr = std.mem.readInt(u32, from[0..4], .little);
            return;
        }
        return error.Unmapped;
    }
};

fn faultCpu(memory: *FaultBus) Cpu {
    var cpu: Cpu = .{ .bus = memory.view() };
    cpu.regs.pc = 0x100;
    cpu.regs.xpsr = regs.xpsr_bits.thumb;
    cpu.regs.control = regs.control_bits.pac_en;
    cpu.regs.pac_key_p = .{ 1, 2, 3, 4 };
    cpu.regs.msp = 0x2000_1000;
    return cpu;
}

const CreatePac = struct {
    // DDI0553B.y ID09082024 E2.1.79 CreatePAC / E2.1.54 ComputePAC, independently
    // evaluated in RA8EMU-A-67; derived M-profile vector, not a published KAT.
    // Key[127:64] = 84BE85CE9804E94B, key[63:0] = EC2802D4E0A488E9.
    const key: qarma.Key = .{ 0xE0A4_88E9, 0xEC28_02D4, 0x9804_E94B, 0x84BE_85CE };
    const pointer: u32 = 0x0800_1235;
    const modifier: u32 = 0x2000_7FF8;
    const code: u32 = 0x1F29_99E8;
};

fn vectorCpu(memory: *FaultBus) Cpu {
    var cpu = faultCpu(memory);
    cpu.regs.pac_key_p = CreatePac.key;
    cpu.regs.lr = CreatePac.pointer;
    cpu.regs.msp = CreatePac.modifier;
    cpu.regs.low[0] = CreatePac.code;
    cpu.regs.low[1] = CreatePac.pointer;
    cpu.regs.low[2] = CreatePac.modifier;
    cpu.regs.low[12] = CreatePac.code;
    return cpu;
}

test "PAC and PACG execute the independent M-profile CreatePAC vector" {
    const forms = [_]struct { hw1: u16, hw2: u16, dst: u4 }{
        .{ .hw1 = 0xF3AF, .hw2 = 0x801D, .dst = 12 }, // pac r12, lr, sp
        .{ .hw1 = 0xFB61, .hw2 = 0xF002, .dst = 0 }, // pacg r0, r1, r2
    };
    for (forms) |form| {
        var memory = FaultBus.withCode(form.hw1, form.hw2);
        var cpu = vectorCpu(&memory);
        cpu.regs.set(form.dst, 0);
        try std.testing.expect(cpu.step() == null);
        try std.testing.expectEqual(CreatePac.code, cpu.regs.get(form.dst));
        try std.testing.expectEqual(@as(u32, 0x104), cpu.regs.pc);
        try std.testing.expectEqual(@as(u32, 0), memory.cfsr);
    }
}

test "AUT, AUTG and BXAUT validate the fixed CreatePAC code and reject corrupted inputs" {
    const forms = [_]struct { hw1: u16, hw2: u16, implicit: bool, branch: bool }{
        .{ .hw1 = 0xF3AF, .hw2 = 0x802D, .implicit = true, .branch = false }, // aut r12, lr, sp
        .{ .hw1 = 0xFB51, .hw2 = 0x0F02, .implicit = false, .branch = false }, // autg r0, r1, r2
        .{ .hw1 = 0xFB51, .hw2 = 0x0F12, .implicit = false, .branch = true }, // bxaut r0, r1, r2
    };
    const Corruption = enum { none, pointer, modifier, code };
    for (forms) |form| {
        for (std.enums.values(Corruption)) |corruption| {
            var memory = FaultBus.withCode(form.hw1, form.hw2);
            var cpu = vectorCpu(&memory);
            const changed: u4 = switch (corruption) {
                .none, .code => if (form.implicit) 12 else 0,
                .pointer => if (form.implicit) 14 else 1,
                .modifier => if (form.implicit) 13 else 2,
            };
            if (corruption != .none) cpu.regs.set(changed, cpu.regs.get(changed) ^ 4);
            const stopped = cpu.step();
            if (corruption == .none) {
                try std.testing.expect(stopped == null);
                const pc: u32 = if (form.branch) CreatePac.pointer & ~@as(u32, 1) else 0x104;
                try std.testing.expectEqual(pc, cpu.regs.pc);
                try std.testing.expectEqual(@as(u32, 0), memory.cfsr);
            } else {
                try std.testing.expectEqual(@as(u32, 0x100), stopped.?.invalid_state);
                try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
                try std.testing.expectEqual(@as(u32, 1 << 17), memory.cfsr);
            }
        }
    }
}

test "a failed AUT reaches the UsageFault INVSTATE latch" {
    var memory: FaultBus = .{};
    var cpu = faultCpu(&memory);
    cpu.regs.lr = 0x0800_1235;
    cpu.regs.low[12] = 0x1234;
    const stopped = cpu.step().?;
    try std.testing.expectEqual(@as(u32, 0x100), stopped.invalid_state);
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 1 << 17), memory.cfsr);
}

test "corrupted-Ra AUTG reaches the UsageFault INVSTATE latch" {
    // DDI0553B.y ID09082024 C2.4.18 AUTG sets UFSR.INVSTATE and raises UsageFault on mismatch.
    var memory = FaultBus.withCode(0xFB51, 0x0F02); // autg r0, r1, r2
    var cpu = faultCpu(&memory);
    cpu.regs.low[1] = 0x0800_4567;
    cpu.regs.low[2] = 0x2000_0020;
    cpu.regs.low[0] = qarma.pac(cpu.regs.low[1], cpu.regs.low[2], cpu.regs.pac_key_p) ^ 1;
    const stopped = cpu.step().?;
    try std.testing.expectEqual(@as(u32, 0x100), stopped.invalid_state);
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 1 << 17), memory.cfsr);
}

test "corrupted-Ra BXAUT latches UsageFault INVSTATE, keeps PC, and does not branch" {
    // DDI0553B.y ID09082024 C2.4.30 BXAUT validates Ra before BranchReturn(R[n], FALSE),
    // latching CFSR.INVSTATE (1 << 17) and keeping PC at BXAUT without branching on mismatch.
    var memory = FaultBus.withCode(0xFB51, 0x0F12); // bxaut r0, r1, r2
    var cpu = faultCpu(&memory);
    cpu.regs.low[1] = 0x0800_4567;
    cpu.regs.low[2] = 0x2000_0020;
    cpu.regs.low[0] = qarma.pac(cpu.regs.low[1], cpu.regs.low[2], cpu.regs.pac_key_p) ^ 1;
    const stopped = cpu.step().?;
    try std.testing.expectEqual(@as(u32, 0x100), stopped.invalid_state);
    try std.testing.expectEqual(@as(u32, 1 << 17), memory.cfsr);
    try std.testing.expectEqual(@as(u32, 0x100), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x0800_4567), cpu.regs.low[1]);
    try std.testing.expectEqual(regs.xpsr_bits.thumb, cpu.regs.xpsr);
}

test "PACG and AUTG use selected GPRs, BXAUT branches after authentication" {
    var cpu = enabledCpu();
    cpu.regs.low[1] = 0x0800_4567;
    cpu.regs.low[2] = 0x2000_0020;
    try execute(&cpu, 0xFB61, 0xF002); // pacg r0, r1, r2
    try std.testing.expectEqual(qarma.pac(cpu.regs.low[1], cpu.regs.low[2], cpu.regs.pac_key_p), cpu.regs.low[0]);
    try execute(&cpu, 0xFB51, 0x0F02); // autg r0, r1, r2
    try execute(&cpu, 0xFB51, 0x0F12); // bxaut r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0x0800_4566), cpu.regs.pc);
}

test "BXAUT with a wrong code in Ra faults and does not branch" {
    var cpu = enabledCpu();
    cpu.regs.pc = 0x0800_0100;
    cpu.regs.low[1] = 0x0800_4567;
    cpu.regs.low[2] = 0x2000_0020;
    cpu.regs.low[0] = qarma.pac(cpu.regs.low[1], cpu.regs.low[2], cpu.regs.pac_key_p) ^ 1;
    try std.testing.expectError(error.InvalidState, execute(&cpu, 0xFB51, 0x0F12)); // bxaut r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0x0800_0100), cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x0800_4567), cpu.regs.low[1]);
}

test "disabled PAC instructions are inert and BXAUT still branches" {
    var cpu: Cpu = .{ .bus = undefined };
    cpu.regs.lr = 0x0800_1235;
    cpu.regs.low[1] = 0x0800_1235;
    try execute(&cpu, 0xF3AF, 0x801D);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.low[12]);
    cpu.regs.lr ^= 4;
    try execute(&cpu, 0xF3AF, 0x802D); // AUT is inert when disabled
    cpu.regs.low[0] = 0xDEAD_BEEF;
    cpu.regs.low[2] = 0x2000_0010;
    // DDI0553B.y ID09082024 B6.1 R XZVW, C2.4.18 AUTG, C2.4.30 BXAUT, C2.4.137 PACG:
    // with PACEnabled() == FALSE, PACG leaves Rd unchanged, AUTG skips validation,
    // and BXAUT skips validation while still branching via BranchReturn(R[n], FALSE).
    try execute(&cpu, 0xFB61, 0xF002); // pacg r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.regs.low[0]);
    try execute(&cpu, 0xFB51, 0x0F02); // autg r0, r1, r2
    try execute(&cpu, 0xFB51, 0x0F12); // bxaut r0, r1, r2
    try std.testing.expectEqual(@as(u32, 0x0800_1234), cpu.regs.pc);
}

test "the instruction group claims PAC, PACBTI, AUT, PACG, AUTG and BXAUT" {
    for ([_]Instr{
        instr(0xF3AF, 0x800D), instr(0xF3AF, 0x801D), instr(0xF3AF, 0x802D),
        instr(0xFB61, 0xF002), instr(0xFB51, 0x0F02), instr(0xFB51, 0x0F12),
    }) |i| try std.testing.expect(pac.group.decode(i) != null);
    try std.testing.expect(pac.group.decode(instr(0xFB51, 0x0F32)) == null);
}

test "LR is a legal Rd, Ra and BXAUT Rn; SP and PC are refused" {
    for ([_]Instr{
        instr(0xFB5E, 0xCF1D), instr(0xFB61, 0xFE02), instr(0xFB51, 0xEF02),
    }) |i| try std.testing.expect(pac.group.decode(i) != null);
    for ([_]Instr{
        instr(0xFB5D, 0xCF1E), instr(0xFB61, 0xFD02), instr(0xFB51, 0xDF02), instr(0xFB51, 0xFF02),
    }) |i| try std.testing.expect(pac.group.decode(i) == null);
}

test "bxaut ip, lr, sp returns through an authenticated LR and faults on a bad code" {
    var cpu = enabledCpu();
    cpu.regs.low[12] = qarma.pac(cpu.regs.lr, cpu.regs.sp(), cpu.regs.pac_key_p);
    try execute(&cpu, 0xFB5E, 0xCF1D);
    try std.testing.expectEqual(@as(u32, 0x0800_1234), cpu.regs.pc);
    cpu.regs.pc = 0x0800_0100;
    cpu.regs.low[12] ^= 1;
    try std.testing.expectError(error.InvalidState, execute(&cpu, 0xFB5E, 0xCF1D));
    try std.testing.expectEqual(@as(u32, 0x0800_0100), cpu.regs.pc);
}

test "PAC, PACG, AUTG, and BXAUT select enable and keys from active CONTROL bank" {
    // DDI0553B.y ID09082024 E2.1.313 PACEnabled, C2.4.18 AUTG, C2.4.30 BXAUT, C2.4.137 PACG.
    for ([_]State{ .secure, .non_secure }) |state| {
        for ([_]bool{ true, false }) |privileged| {
            var cpu = enabledCpu();
            cpu.regs.control = 0;
            cpu.regs.pac_key_u = .{ 5, 6, 7, 8 };
            if (state == .non_secure) cpu.banked.switchTo(&cpu.regs, state);
            const bit = if (privileged) regs.control_bits.pac_en else regs.control_bits.upac_en;
            cpu.regs.control = bit | (if (privileged) 0 else regs.control_bits.npriv);
            const key = if (privileged) cpu.regs.pac_key_p else cpu.regs.pac_key_u;

            cpu.regs.low[12] = 0xA5A5_5A5A;
            try execute(&cpu, 0xF3AF, 0x801D);
            try std.testing.expectEqual(qarma.pac(cpu.regs.lr, cpu.regs.sp(), key), cpu.regs.low[12]);

            cpu.regs.low[1] = 0x0800_4567;
            cpu.regs.low[2] = 0x2000_0020;
            try execute(&cpu, 0xFB61, 0xF002); // pacg r0, r1, r2
            try std.testing.expectEqual(qarma.pac(cpu.regs.low[1], cpu.regs.low[2], key), cpu.regs.low[0]);
            try execute(&cpu, 0xFB51, 0x0F02); // autg r0, r1, r2
            cpu.regs.low[0] ^= 1;
            try std.testing.expectError(error.InvalidState, execute(&cpu, 0xFB51, 0x0F02));
            cpu.regs.low[0] ^= 1;
            try execute(&cpu, 0xFB51, 0x0F12); // bxaut r0, r1, r2
            try std.testing.expectEqual(@as(u32, 0x0800_4566), cpu.regs.pc);
        }
    }
}

test "disabled PACG, AUTG, and BXAUT across Secure and Non-secure CONTROL banks" {
    // DDI0553B.y ID09082024 C2.4.18 (AUTG), C2.4.30 (BXAUT), C2.4.137 (PACG),
    // B6.1 (R XZVW), and E2.1.313 (PACEnabled): when the active privilege enable bit
    // in the active Security CONTROL bank is clear, PACG preserves Rd, AUTG skips the
    // check, and BXAUT branches without raising UsageFault.
    for ([_]State{ .secure, .non_secure }) |state| {
        for ([_]bool{ true, false }) |privileged| {
            var memory = FaultBus.withCode(0xFB51, 0x0F12); // bxaut r0, r1, r2
            var cpu = faultCpu(&memory);
            const other: State = if (state == .secure) .non_secure else .secure;
            cpu.banked.switchTo(&cpu.regs, other);
            cpu.regs.control = regs.control_bits.pac_en | regs.control_bits.upac_en;
            cpu.banked.switchTo(&cpu.regs, state);
            cpu.regs.control = if (privileged)
                regs.control_bits.upac_en
            else
                regs.control_bits.npriv | regs.control_bits.pac_en;
            cpu.regs.pac_key_u = .{ 5, 6, 7, 8 };
            cpu.regs.low[0] = 0xDEAD_BEEF;
            cpu.regs.low[1] = 0x0800_4567;
            cpu.regs.low[2] = 0x2000_0020;

            try execute(&cpu, 0xFB61, 0xF002); // pacg r0, r1, r2
            try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), cpu.regs.low[0]);
            try execute(&cpu, 0xFB51, 0x0F02); // autg r0, r1, r2 ignores corrupted Ra
            try std.testing.expect(cpu.step() == null); // bxaut r0, r1, r2 branches
            try std.testing.expectEqual(@as(u32, 0), memory.cfsr);
            try std.testing.expectEqual(@as(u32, 0x0800_4566), cpu.regs.pc);
        }
    }
}

test "BXAUT is not BTI-setting and honors pending EPSR.B" {
    // DDI0553B.y ID09082024 C2.4.30 (BranchReturn(R[n], FALSE)), B6.1 I HLLR / R YBDN.
    var clear_mem = FaultBus.withCode(0xFB51, 0x0F12); // bxaut r0, r1, r2
    var clear_cpu = faultCpu(&clear_mem);
    clear_cpu.regs.control = regs.control_bits.pac_en | regs.control_bits.bti_en;
    clear_cpu.regs.low[1] = 0x0800_4567;
    clear_cpu.regs.low[2] = 0x2000_0020;
    clear_cpu.regs.low[0] = qarma.pac(clear_cpu.regs.low[1], clear_cpu.regs.low[2], clear_cpu.regs.pac_key_p);
    try std.testing.expect(clear_cpu.step() == null);
    try std.testing.expectEqual(@as(u32, 0x0800_4566), clear_cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), clear_cpu.regs.xpsr & regs.xpsr_bits.bti);

    var bti_mem = FaultBus.withCode(0xFB51, 0x0F12);
    var bti_cpu = faultCpu(&bti_mem);
    bti_cpu.regs.control = regs.control_bits.pac_en | regs.control_bits.bti_en;
    bti_cpu.regs.xpsr = regs.xpsr_bits.thumb | regs.xpsr_bits.bti;
    bti_cpu.regs.low[1] = 0x0800_4567;
    bti_cpu.regs.low[2] = 0x2000_0020;
    bti_cpu.regs.low[0] = qarma.pac(bti_cpu.regs.low[1], bti_cpu.regs.low[2], bti_cpu.regs.pac_key_p);
    const stopped = bti_cpu.step().?;
    try std.testing.expectEqual(@as(u32, 0x100), stopped.invalid_state);
    try std.testing.expectEqual(@as(u32, 1 << 17), bti_mem.cfsr);
    try std.testing.expectEqual(@as(u32, 0x100), bti_cpu.regs.pc);
}
