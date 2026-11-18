//! Covers `src/chip/core/machine/scs.zig` and end-to-end per-core SCS behavior
//! on a sole Cortex-M33 configuration alongside unchanged RA8D2/RA8P1 defaults.
const ra8 = @import("ra8");
const std = @import("std");

const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
const catalog = ra8.chip.core.machine.catalog;
const clocks = ra8.chip.periph.clocks;
const core_mod = ra8.chip.core.machine.core;
const cpu_mod = ra8.chip.core.cpu.cpu;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const irq_source = ra8.chip.periph.irq_source;
const memmap = ra8.chip.core.memmap;
const NvicSource = ra8.chip.core.cpu.exception.nvic_source.NvicSource;
const registry = ra8.chip.periph.registry;
const sau = ra8.chip.periph.sau;
const scs = core_mod.scs;
const Store = ra8.chip.core.cpu.memory.store.Store;
const systick_bank = ra8.chip.core.systick_bank;

test "ScsConfig helpers compute word counts, partial tail masks, priority masks and defaults" {
    const def: scs.ScsConfig = .{};
    try std.testing.expectEqual(@as(u16, 3), def.irqWords());
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), def.tailIrqMask());
    try std.testing.expectEqual(@as(u8, 0xF0), def.prioMask());
    try std.testing.expectEqual(@as(u4, 8), def.effectiveDwt(true));
    try std.testing.expectEqual(@as(u4, 4), def.effectiveDwt(false));
    try std.testing.expectEqual(@as(u8, 8), def.effectiveSau(true));
    try std.testing.expectEqual(@as(u8, 0), def.effectiveSau(false));

    const odd: scs.ScsConfig = .{
        .irq_lines = 98,
        .prio_bits = 3,
        .sau_regions = 0,
        .dwt_comparators = 2,
    };
    try std.testing.expectEqual(@as(u16, 4), odd.irqWords());
    try std.testing.expectEqual(@as(u32, 0x0000_0003), odd.tailIrqMask());
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), odd.wordIrqMask(2));
    try std.testing.expectEqual(@as(u32, 0x0000_0003), odd.wordIrqMask(3));
    try std.testing.expectEqual(@as(u32, 0), odd.wordIrqMask(4));
    try std.testing.expectEqual(@as(u8, 0xE0), odd.prioMask());
    try std.testing.expectEqual(@as(u4, 2), odd.effectiveDwt(false));
    try std.testing.expectEqual(@as(u8, 0), odd.effectiveSau(true));

    const zero_irqs: scs.ScsConfig = .{ .irq_lines = 0, .prio_bits = 0 };
    try std.testing.expectEqual(@as(u16, 0), zero_irqs.irqWords());
    try std.testing.expectEqual(@as(u32, 0), zero_irqs.tailIrqMask());
    try std.testing.expectEqual(@as(u8, 0), zero_irqs.prioMask());

    const max_irqs: scs.ScsConfig = .{ .irq_lines = 480, .prio_bits = 8 };
    try std.testing.expectEqual(@as(u16, 15), max_irqs.irqWords());
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), max_irqs.tailIrqMask());
    try std.testing.expectEqual(@as(u8, 0xFF), max_irqs.prioMask());
}

test "catalog RA8D2 and RA8P1 cores preserve default SCS parameters" {
    for ([_]*const ra8.chip.core.machine.Machine{ &catalog.ra8d2, &catalog.ra8p1 }) |m| {
        const c0 = m.primary();
        const c1 = m.core(.cpu1).?;
        try std.testing.expectEqual(scs.ScsConfig{}, c0.scs);
        try std.testing.expectEqual(scs.ScsConfig{}, c1.scs);
        try std.testing.expectEqual(@as(u4, 8), c0.scs.effectiveDwt(c0.profile.v8_1m));
        try std.testing.expectEqual(@as(u4, 4), c1.scs.effectiveDwt(c1.profile.v8_1m));
    }
}

const Rig = struct {
    store: Store,
    periph: registry.Bus,
    board_bus: BoardBus = undefined,
    pending: NvicSource = undefined,
    cpu: cpu_mod.Cpu = undefined,

    fn open(self: *Rig, desc: core_mod.Core) !void {
        self.* = .{
            .store = try Store.init(null),
            .periph = registry.Bus.init(std.testing.allocator),
        };
        const mem: Guest = .{ .store = &self.store };
        self.board_bus = .{
            .memory = GuestBus.of(&mem, false),
            .periph = &self.periph,
            .scs = .{
                .config = desc.scs,
                .systicks = desc.systicks,
                .has_security = desc.security,
                .dwt_numcomp = desc.scs.effectiveDwt(desc.profile.v8_1m),
                .fpb_wired = true,
            },
        };
        self.pending = .{ .model = .{
            .irq_lines = desc.scs.irq_lines,
            .prio_bits = desc.scs.prio_bits,
            .systicks = desc.systicks,
        } };
        self.cpu = .{
            .bus = self.board_bus.view(),
            .source = self.pending.source(),
            .profile = desc.profile,
        };
        self.board_bus.security = if (desc.security) &self.cpu.banked else null;
        self.board_bus.scs.fp = &self.cpu.fp;
        self.pending.banked = &self.cpu.banked;
    }

    fn deinit(self: *Rig) void {
        self.periph.deinit();
        self.store.deinit();
    }

    fn guest(self: *Rig) Guest {
        return .{ .store = &self.store };
    }
};

fn putHalf(g: Guest, address: u32, hw: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, hw, .little);
    try g.write(address, &bytes);
}

test "sole Cortex-M33 honors init_vtor across cold and warm reset and dispatches tail IRQ" {
    const vtor_base: u32 = 0x0200_0000;
    const main_pc: u32 = 0x0200_0400;
    const isr_pc: u32 = 0x0200_0500;
    const flag_addr: u32 = 0x2200_0100;
    const desc = core_mod.cortexM33(.{
        .security = false,
        .fpu = .single,
        .systicks = 1,
        .scs = .{ .irq_lines = 37, .prio_bits = 3, .init_vtor = vtor_base },
    });
    var rig: Rig = undefined;
    try rig.open(desc);
    defer rig.deinit();
    var g = rig.guest();

    try g.writeWord(vtor_base + 0, 0x2200_1000);
    try g.writeWord(vtor_base + 4, main_pc | 1);
    // IRQ 36 (last valid line when irq_lines == 37) is exception 52.
    try g.writeWord(vtor_base + 52 * 4, isr_pc | 1);
    try g.writeWord(vtor_base + 53 * 4, 0x0200_0600 | 1);
    // Main loop: NOP; NOP; NOP.
    try putHalf(g, main_pc + 0, 0xBF00);
    try putHalf(g, main_pc + 2, 0xBF00);
    try putHalf(g, main_pc + 4, 0xBF00);
    // ISR: MOVS r0, #0x5A; STR r0, [r1]; BX lr.
    try putHalf(g, isr_pc + 0, 0x205A);
    try putHalf(g, isr_pc + 2, 0x6008);
    try putHalf(g, isr_pc + 4, 0x4770);

    try rig.cpu.reset(vtor_base);
    rig.cpu.regs.low[1] = flag_addr;
    try std.testing.expectEqual(vtor_base, try rig.cpu.bus.readWord(memmap.scb.vtor));

    var direct: irq_source.DirectLines = .{};
    const src = direct.irqSource();
    // Enable words 1 bits 4 (IRQ 36) and 5 (IRQ 37, invalid).
    try rig.cpu.bus.writeWord(memmap.nvic.iser + 4, (1 << 4) | (1 << 5));
    try src.raise(&g, desc.scs.irq_lines, 37);
    try std.testing.expectEqual(@as(u64, 1), direct.dropped);
    try std.testing.expectEqual(.count, std.meta.activeTag(rig.cpu.run(1)));
    try std.testing.expectEqual(main_pc + 2, rig.cpu.regs.pc);

    // Raise valid last line 36: enters ISR, writes flag, returns via BX LR.
    try src.raise(&g, desc.scs.irq_lines, 36);
    try std.testing.expectEqual(.count, std.meta.activeTag(rig.cpu.run(1)));
    try std.testing.expectEqual(isr_pc + 2, rig.cpu.regs.pc);
    try std.testing.expectEqual(.count, std.meta.activeTag(rig.cpu.run(2)));
    try std.testing.expectEqual(main_pc + 2, rig.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0x5A), try g.readWord(flag_addr));

    // Relocate VTOR then warm-reset: init_vtor is restored into SCB.VTOR.
    try rig.cpu.bus.writeWord(memmap.scb.vtor, 0x2200_0800);
    try rig.cpu.reset(vtor_base);
    try std.testing.expectEqual(vtor_base, try rig.cpu.bus.readWord(memmap.scb.vtor));
}

test "sole Cortex-M33 enforces prio_bits masking on preemption and BASEPRI" {
    const vtor_base: u32 = 0x0200_0000;
    const desc = core_mod.cortexM33(.{
        .security = false,
        .fpu = .single,
        .systicks = 0,
        .scs = .{ .irq_lines = 16, .prio_bits = 3, .init_vtor = vtor_base },
    });
    var rig: Rig = undefined;
    try rig.open(desc);
    defer rig.deinit();
    const g = rig.guest();
    try g.writeWord(vtor_base + 0, 0x2200_1000);
    try g.writeWord(vtor_base + 4, 0x0200_0201);
    try g.writeWord(vtor_base + 16 * 4, 0x0200_0301);
    try g.writeWord(vtor_base + 17 * 4, 0x0200_0401);
    try putHalf(g, 0x0200_0200, 0xBF00);
    try putHalf(g, 0x0200_0300, 0xBF00);
    try putHalf(g, 0x0200_0400, 0xBF00);
    try rig.cpu.reset(vtor_base);

    // With prio_bits = 3 (mask 0xE0), 0x42 -> 0x40 on IRQ0 and 0x2F -> 0x20 on IRQ1.
    try rig.cpu.bus.writeWord(memmap.nvic.ipr, 0x0000_2F42);
    try std.testing.expectEqual(@as(u32, 0x0000_2040), try rig.cpu.bus.readWord(memmap.nvic.ipr));

    // MSR BASEPRI, r0 with 0x5C stores 0x40 and masks IRQ0 at 0x40 while allowing IRQ1 at 0x20.
    rig.cpu.regs.low[0] = 0x5C;
    try putHalf(g, 0x0200_0200, 0xF380);
    try putHalf(g, 0x0200_0202, 0x8811);
    try putHalf(g, 0x0200_0204, 0xBF00);
    try std.testing.expectEqual(.count, std.meta.activeTag(rig.cpu.run(1)));
    try std.testing.expectEqual(@as(u32, 0x40), rig.cpu.regs.basepri);

    try rig.cpu.bus.writeWord(memmap.nvic.iser, 0b11);
    try rig.cpu.bus.writeWord(memmap.nvic.ispr, 0b01);
    try std.testing.expectEqual(.count, std.meta.activeTag(rig.cpu.run(1)));
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.regs.xpsr & 0x1FF);

    try rig.cpu.bus.writeWord(memmap.nvic.ispr, 0b10);
    try std.testing.expectEqual(.count, std.meta.activeTag(rig.cpu.run(1)));
    try std.testing.expectEqual(@as(u32, 17), rig.cpu.regs.xpsr & 0x1FF);
}

test "SysTick count 0, 1 and 2 control timer ticking, NS alias visibility and SYST_CALIB" {
    for ([_]u2{ 0, 1, 2 }) |count| {
        const desc = core_mod.cortexM33(.{
            .security = count == 2,
            .fpu = .single,
            .systicks = count,
            .scs = .{ .syst_calib = 0x4000_270F },
        });
        var rig: Rig = undefined;
        try rig.open(desc);
        defer rig.deinit();
        const g = rig.guest();
        const bus = rig.cpu.bus;

        try bus.writeWord(memmap.syst.rvr, 9);
        try bus.writeWord(memmap.syst.csr, clocks.csr_enable | clocks.csr_tickint);
        try bus.writeWord(memmap.syst.calib, 0);
        try std.testing.expectEqual(
            if (count == 0) @as(u32, 0) else @as(u32, 0x4000_270F),
            try bus.readWord(memmap.syst.calib),
        );

        var s_clk: clocks.Clocks = .{};
        s_clk.words.present = count >= 1;
        var ns_clk: clocks.Clocks = .{ .words = systick_bank.non_secure_words };
        ns_clk.words.present = count >= 2;
        try s_clk.advance(g, 10);
        try ns_clk.advanceSysTick(g, 10);
        try std.testing.expectEqual(if (count >= 1) @as(u64, 1) else @as(u64, 0), s_clk.pends);

        try bus.writeWord(memmap.syst.rvr + 0x20000, 9);
        try bus.writeWord(memmap.syst.csr + 0x20000, clocks.csr_enable | clocks.csr_tickint);
        try ns_clk.advanceSysTick(g, 10);
        try std.testing.expectEqual(if (count == 2) @as(u64, 1) else @as(u64, 0), ns_clk.pends);
    }
}

test "sau_regions = 0 sets SAU_TYPE = 0 and defers security attribution purely to IDAU" {
    var unit = sau.Sau.init();
    unit.setRegions(0);
    try std.testing.expectEqual(@as(u32, 0), unit.typeValue());
    _ = unit.observe(memmap.sau.rnr, 0);
    _ = unit.observe(memmap.sau.rbar, 0x2000_0000);
    _ = unit.observe(memmap.sau.rlar, 0x2000_FFE0 | sau.field.rlar_enable);
    _ = unit.observe(memmap.sau.ctrl, sau.field.ctrl_enable);
    try std.testing.expect(!unit.on());
    try std.testing.expectEqual(@as(u8, 0), unit.programmed());
    try std.testing.expectEqual(
        sau.attribution.State.non_secure,
        sau.attribution.attribute(&unit, .{ .state = .non_secure }, 0x2000_0100).state,
    );
    try std.testing.expectEqual(
        sau.attribution.State.secure,
        sau.attribution.attribute(&unit, .{ .state = .secure }, 0x0200_0100).state,
    );
}
