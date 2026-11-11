//! Covers AM09 CPU store-family hook completeness: all 14 Thumb/FP/MVE store
//! instruction groups executed through `Cpu` over `MemoryBus` (both fast-path
//! H2 and vtable H1), verified against `ShadowOracle` and `Recording.undo`.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.chip.core.memmap;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const regs_mod = ra8.chip.core.cpu.regs;
const Instr = ra8.chip.core.cpu.instr.Instr;
const decode = ra8.chip.core.cpu.decode;
const mve = ra8.chip.core.cpu.mve;
const Store = ra8.chip.core.cpu.memory.store.Store;
const MemoryBus = ra8.chip.core.cpu.memory.memory_bus.MemoryBus;
const trail_mod = ra8.session.history_trail;
const ShadowOracle = ra8.session.history_shadow_oracle.ShadowOracle;

const code_at: u32 = memmap.mram_base + 0x200;
const data_at: u32 = memmap.sram_base + 0x400;
const seed_len: usize = 0x100;

const Case = struct {
    group: []const u8,
    hw1: u16,
    hw2: ?u16 = null,
    pre_ldrex: bool = false,
};

const families = [_]Case{
    // 1. Thumb-1 narrow immediate: STR r1, [r0, #4]
    .{ .group = "ldst_imm", .hw1 = 0x6041 },
    // 2. Thumb-1 narrow register offset: STR r1, [r0, r2]
    .{ .group = "ldst_reg", .hw1 = 0x5081 },
    // 3. Thumb-2 wide immediate pre-index: STR.W r1, [r0, #8]!
    .{ .group = "ldst_wide", .hw1 = 0xF840, .hw2 = 0x1F08 },
    // 4. Thumb-2 wide shifted register: STR.W r1, [r0, r2, LSL #2]
    .{ .group = "ldst_reg_wide", .hw1 = 0xF840, .hw2 = 0x1022 },
    // 5. Dual store: STRD r1, r2, [r0, #0]
    .{ .group = "ldrd_strd", .hw1 = 0xE9C0, .hw2 = 0x1200 },
    // 6. Thumb-1 narrow store multiple: STMIA r0!, {r1, r2}
    .{ .group = "ldm_stm", .hw1 = 0xC006 },
    // 7. Thumb-2 wide store multiple: STMDB r0!, {r1, r2, r3}
    .{ .group = "ldm_stm_wide", .hw1 = 0xE920, .hw2 = 0x000E },
    // 8. Stack push: PUSH {r1, r2, lr}
    .{ .group = "push_pop", .hw1 = 0xB506 },
    // 9. Exclusive store: LDREX r3, [r0] + STREX r4, r1, [r0]
    .{ .group = "exclusive", .hw1 = 0xE840, .hw2 = 0x1400, .pre_ldrex = true },
    // 10. Store-release: STL r1, [r0]
    .{ .group = "acq_rel", .hw1 = 0xE8C0, .hw2 = 0x1FAF },
    // 11. Floating-point store: VSTR.32 s0, [r0, #0]
    .{ .group = "fp_mem", .hw1 = 0xED80, .hw2 = 0x0A00 },
    // 12. Security lazy FP context store: VLSTM r0
    .{ .group = "vlldm_vlstm", .hw1 = 0xEC20, .hw2 = 0x0A00 },
    // 13. MVE contiguous narrowing vector store: VSTRB.32 q0, [r0, #0]
    .{ .group = "mve_vldr_wide", .hw1 = 0xED80, .hw2 = 0x0F00 },
    // 14. MVE 64-bit scatter vector store: VSTRD.64 q0, [r0, q1]
    .{ .group = "mve_gather64", .hw1 = 0xEC80, .hw2 = 0x0FD2 },
};

fn putHalf(store: *Store, at: u32, hw: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, hw, .little);
    try store.rawWrite(at, &b);
}

fn verifyDecode(one: Case) !void {
    const instr: Instr = if (one.hw2) |hw2|
        .{ .address = code_at, .hw1 = one.hw1, .hw2 = hw2, .size = 4 }
    else
        .{ .address = code_at, .hw1 = one.hw1, .size = 2 };
    const hit = decode.decode(instr) orelse return error.UndecodedStoreFamily;
    try std.testing.expectEqualStrings(one.group, hit.group);
}

fn seedCpu(cpu: *Cpu) void {
    cpu.regs.xpsr = regs_mod.xpsr_bits.thumb;
    cpu.regs.pc = code_at;
    cpu.regs.msp = data_at + 0xC0;
    cpu.regs.set(0, data_at + 0x40);
    cpu.regs.set(1, 0xCAFE_BABE);
    cpu.regs.set(2, 0x0000_0008);
    cpu.regs.set(3, 0xDEAD_BEEF);
    cpu.regs.lr = 0x0200_0101;
    cpu.banked.current = .secure;
    cpu.regs.control = regs_mod.control_bits.sfpa | regs_mod.control_bits.fpca;
    cpu.fp.cpacr = 0x00F0_0000;
    cpu.fp.context.fpccr.lspen = 0;
    cpu.fp.context.fpccr.lspact = 0;
    cpu.fp.bank.writeS(0, 0x3F80_0000);
    mve.qreg.write(&cpu.fp.bank, 0, 0x11223344_55667788_99AABBCC_DDEEFF01);
    mve.qreg.write(&cpu.fp.bank, 1, (@as(u128, 16) << 64) | 0);
}

fn runOneFamily(one: Case, fast_enabled: bool) !void {
    try verifyDecode(one);
    var store = try Store.init(null);
    defer store.deinit();

    var pre_data: [seed_len]u8 = undefined;
    for (&pre_data, 0..) |*byte, idx| byte.* = @truncate(idx *% 37 +% 0x5A);
    try store.rawWrite(data_at, &pre_data);

    var cursor = code_at;
    if (one.pre_ldrex) {
        try putHalf(&store, cursor, 0xE850);
        try putHalf(&store, cursor + 2, 0x3F00);
        cursor += 4;
    }
    try putHalf(&store, cursor, one.hw1);
    cursor += 2;
    if (one.hw2) |hw2| {
        try putHalf(&store, cursor, hw2);
        cursor += 2;
    }

    var slots: [2]u64 = .{ 1, 0 };
    var rec = trail_mod.Recording.init(std.testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();
    rec.arm();

    var oracle = ShadowOracle.init(std.testing.allocator);
    defer oracle.deinit();
    try oracle.trackStore(&store);

    var mem_bus = MemoryBus{ .store = &store, .initiator = .cpu0, .fast_enabled = fast_enabled };
    var cpu: Cpu = .{ .bus = mem_bus.view() };
    seedCpu(&cpu);

    const steps: u64 = if (one.pre_ldrex) 2 else 1;
    const stop = cpu.run(steps);
    try std.testing.expectEqual(.count, std.meta.activeTag(stop));
    try std.testing.expect(rec.record_count > 0);
    try std.testing.expect(!std.mem.eql(u8, &pre_data, store.span(data_at, seed_len).?));

    try oracle.verifyRecording(rec.slice());

    const undone = try rec.undo();
    try std.testing.expect(undone > 0);
    try std.testing.expectEqualSlices(u8, &pre_data, store.span(data_at, seed_len).?);
}

test "all 14 CPU store instruction families hook pre-images and undo cleanly" {
    for (families) |one| {
        try runOneFamily(one, false);
        try runOneFamily(one, true);
    }
}
