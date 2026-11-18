//! Covers src/chip/core/machine/memory.zig: machine-driven regions, aliases,
//! permissions, MMIO windows, block-cache invalidation, loader checks, vendor
//! IDAU callback, and absence of phantom RA8D2 regions (RA8EMU-1343).
const cli_app = @import("cli_app");
const ra8 = @import("ra8");
const std = @import("std");

const BlockCache = ra8.chip.core.cpu.block_cache.BlockCache;
const Board = ra8.board.board.Board;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const cpu_snap = ra8.chip.core.cpu.snapshot;
const decode = ra8.chip.core.cpu.decode;
const elf = ra8.board.image.elf;
const Guest = ra8.chip.core.cpu.memory.guest.Guest;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const loader = ra8.chip.core.cpu.memory.load;
const machine_mod = ra8.chip.core.machine;
const main_path = cli_app.zig.run.main_path;
const mem_desc = machine_mod.memory;
const Parts = cli_app.parts.Parts;
const read_image = ra8.board.image.load;
const registry = ra8.chip.periph.registry;
const sau_attr = ra8.chip.periph.sau.attribution;
const SauSource = ra8.chip.core.cpu.cpu.sau_source.SauSource;
const Store = ra8.chip.core.cpu.memory.store.Store;

const page: usize = 0x1000;
const flash_base: u32 = 0x0800_0000;
const flash_size: u32 = 0x0001_0000;
const ns_flash_base: u32 = 0x0C00_0000;
const sram_base: u32 = 0x2000_0000;
const sram_size: u32 = 0x0000_8000;
const ns_sram_base: u32 = 0x3000_0000;
const data_base: u32 = 0x2800_0000;
const data_size: u32 = 0x0000_1000;
const cfsr_addr: u32 = 0xE000_ED28;
const bfar_addr: u32 = 0xE000_ED38;
const bfsr_preciserr: u32 = 1 << 9;
const bfsr_ibuserr: u32 = 1 << 8;

fn customIdau(_: ?*const anyopaque, address: u32) sau_attr.Idau {
    if (address >= 0xE000_0000) return .{ .state = .non_secure, .exempt = true, .region = 0 };
    if (address >= flash_base and address < flash_base + flash_size) return .{ .state = .callable, .region = 10 };
    if (address >= ns_flash_base and address < ns_flash_base + flash_size) return .{ .state = .non_secure, .region = 11 };
    if (address >= sram_base and address < sram_base + sram_size) return .{ .state = .secure, .region = 12 };
    if (address >= ns_sram_base and address < ns_sram_base + sram_size) return .{ .state = .non_secure, .region = 13 };
    if (address >= 0x4000_0000 and address < 0x5000_0000) return .{ .state = .secure, .region = 14 };
    return .{ .state = .non_secure, .region = 15 };
}

const small_regions = [_]mem_desc.Region{
    .{
        .name = "FLASH",
        .base = flash_base,
        .size = flash_size,
        .perms = .{ .read = true, .write = false, .exec = true },
        .track_code = true,
        .role = .flash,
    },
    .{
        .name = "SRAM",
        .base = sram_base,
        .size = sram_size,
        .shared = false,
        .track_code = true,
        .role = .sram,
    },
    .{ .name = "DATA", .base = data_base, .size = data_size, .perms = .{ .read = true, .write = true, .exec = false } },
    .{ .name = "PPB", .base = 0xE000_0000, .size = 0x0010_0000, .perms = .{ .exec = false }, .role = .ppb },
};

const small_aliases = [_]mem_desc.Alias{
    .{ .name = "NS_FLASH", .view = ns_flash_base, .of = flash_base, .size = flash_size, .perms = .{ .write = false } },
    .{ .name = "NS_SRAM", .view = ns_sram_base, .of = sram_base, .size = sram_size },
};

const small_mmio = [_]mem_desc.MmioWindow{
    .{ .base = 0x4000_0000, .size = 0x0000_2000, .ns_alias = 0x5000_0000 },
    .{ .base = 0x407E_0000, .size = 0x0000_1000, .ns_alias = null },
};

const small_map: mem_desc.MemoryMap = .{
    .regions = &small_regions,
    .aliases = &small_aliases,
    .mmio = &small_mmio,
    .unknown_mmio = .fault,
    .idau = .{ .answerFn = customIdau },
};

const custom_m33: machine_mod.Machine = .{
    .name = "custom-m33",
    .label = "CUSTOM-M33",
    .cores = .{ .primary = machine_mod.core.cortexM33(.{ .security = true, .fpu = .single, .systicks = 2 }) },
    .memory = &small_map,
    .part = .ra8d2,
};

fn makeElf(load_base: u32, sp: u32, code: []const u16, pool: []const u32) [page * 2]u8 {
    var file: [page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    const reset_at = load_base + 0x40;
    const fault_at = load_base + 0xA0;
    head.* = .{
        .magic = .{ 0x7f, 'E', 'L', 'F' },
        .class = 1,
        .data = 1,
        .version = 1,
        .osabi = 0,
        .abiversion = 0,
        .pad = @splat(0),
        .e_type = 2,
        .e_machine = elf.em_arm,
        .e_version = 1,
        .e_entry = reset_at | 1,
        .e_phoff = @sizeOf(elf.Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Header),
        .e_phentsize = @sizeOf(elf.ProgramHeader),
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const ph: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    ph.* = .{
        .p_type = elf.pt_load,
        .p_offset = page,
        .p_vaddr = load_base,
        .p_paddr = load_base,
        .p_filesz = 0x100,
        .p_memsz = 0x100,
        .p_flags = 5,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], sp, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], reset_at | 1, .little);
    for ([_]usize{ 12, 16, 20, 24, 28 }) |off| {
        std.mem.writeInt(u32, file[page + off ..][0..4], fault_at | 1, .little);
    }
    for (code, 0..) |hw, idx| std.mem.writeInt(u16, file[page + 0x40 + idx * 2 ..][0..2], hw, .little);
    for (pool, 0..) |w, idx| std.mem.writeInt(u32, file[page + 0x60 + idx * 4 ..][0..4], w, .little);
    // Fault handler: copy CFSR and BFAR into SRAM[0] and SRAM[4], then loop.
    const fh = [_]u16{ 0x4803, 0x4904, 0x6802, 0x600A, 0x6903, 0x604B, 0xE7FE, 0xBF00 };
    for (fh, 0..) |hw, idx| std.mem.writeInt(u16, file[page + 0xA0 + idx * 2 ..][0..2], hw, .little);
    std.mem.writeInt(u32, file[page + 0xB0 ..][0..4], cfsr_addr, .little);
    std.mem.writeInt(u32, file[page + 0xB4 ..][0..4], sram_base, .little);
    return file;
}

fn runCustomElf(bytes: []const u8) !struct { cfsr: u32, bfar: u32, blocks: usize } {
    const loaded = try elf.Image.init(bytes);
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    const options: cli_app.cli.Options = .{ .path = "x.elf", .machine = &custom_m33, .instructions = 24 };
    try main_path.fit(&board, std.testing.allocator, std.testing.io, options);
    _ = try main_path.prepare(&cpu0, &board, std.testing.io, loaded, &parts, options);
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    _ = try cli_app.zig.run.run(
        &out.writer,
        std.testing.io,
        cpu0.own(),
        &board,
        &parts.timebase,
        loaded,
        options,
        flash_base,
        null,
        null,
        .{},
    );
    return .{
        .cfsr = try cpu0.own().readWord(sram_base),
        .bfar = try cpu0.own().readWord(sram_base + 4),
        .blocks = board.bus.count,
    };
}

test "aliases share bytes on both slow and direct paths, and boundaries and read-only flash fault" {
    var store = try Store.initFor(null, &small_map);
    defer store.deinit();
    try store.program(.none, flash_base, &.{ 0x12, 0x34, 0x56, 0x78 });
    const guest: Guest = .{ .store = &store, .initiator = .cpu0 };
    for ([_]bool{ false, true }) |fast| {
        var gb = GuestBus.of(&guest, fast);
        const b = gb.view();
        try std.testing.expectEqual(@as(u32, 0x7856_3412), try b.readWord(flash_base));
        try std.testing.expectEqual(@as(u32, 0x7856_3412), try b.readWord(ns_flash_base));
        try std.testing.expectError(error.Unmapped, b.writeWord(flash_base, 0xDEAD_BEEF));
        try std.testing.expectError(error.Unmapped, b.writeWord(ns_flash_base, 0xDEAD_BEEF));
        try b.writeWord(sram_base + sram_size - 4, 0xCAFE_BABE);
        try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), try b.readWord(ns_sram_base + sram_size - 4));
        try b.write(ns_sram_base + sram_size - 1, &.{0x99});
        try std.testing.expectEqual(@as(u8, 0x99), store.span(sram_base + sram_size - 1, 1).?[0]);
        for ([_]u32{
            flash_base + flash_size,
            ns_flash_base + flash_size,
            sram_base + sram_size,
            ns_sram_base + sram_size,
            data_base + data_size,
        }) |past| {
            var one: [1]u8 = undefined;
            try std.testing.expectError(error.Unmapped, b.read(past, &one));
            try std.testing.expectError(error.Unmapped, b.write(past, &.{1}));
        }
    }
    var check_gb = GuestBus.of(&guest, true);
    try std.testing.expect(!check_gb.view().allowsExec(data_base, 2));
    try std.testing.expect(check_gb.view().allowsExec(flash_base, 2));
}

test "direct path honors unread flash, read-only SRAM, and narrower or stricter aliases" {
    const strict_regions = [_]mem_desc.Region{
        .{ .name = "FLASH", .base = 0x0800_0000, .size = 0x2000, .perms = .{ .read = false, .write = false }, .role = .flash },
        .{ .name = "SRAM", .base = 0x2000_0000, .size = 0x2000, .perms = .{ .read = true, .write = false }, .role = .sram },
    };
    const strict_aliases = [_]mem_desc.Alias{
        .{ .name = "HALF_SRAM", .view = 0x3000_0000, .of = 0x2000_0000, .size = 0x1000, .perms = .{ .read = true, .write = true } },
    };
    const strict_map: mem_desc.MemoryMap = .{ .regions = &strict_regions, .aliases = &strict_aliases };
    var store = try Store.initFor(null, &strict_map);
    defer store.deinit();
    try store.program(.none, 0x2000_0000, &.{ 0xAA, 0xBB, 0xCC, 0xDD });
    const guest: Guest = .{ .store = &store, .initiator = .cpu0 };
    for ([_]bool{ false, true }) |fast| {
        var gb = GuestBus.of(&guest, fast);
        const b = gb.view();
        try std.testing.expectError(error.Unmapped, b.readWord(0x0800_0000));
        try std.testing.expectEqual(@as(u32, 0xDDCC_BBAA), try b.readWord(0x2000_0000));
        try std.testing.expectError(error.Unmapped, b.writeWord(0x2000_0000, 0x1122_3344));
        try b.writeWord(0x3000_0FFC, 0x5566_7788);
        try std.testing.expectEqual(@as(u32, 0x5566_7788), try b.readWord(0x2000_0FFC));
        try std.testing.expectError(error.Unmapped, b.readWord(0x3000_1000));
        try std.testing.expectError(error.Unmapped, b.writeWord(0x3000_1000, 1));
    }
}

test "smaller machine map has no phantom RA8D2 RAM, external, or MMIO regions" {
    // ldr r1, [pc, #28]; ldr r2, [r1]; b .; nop
    const code = [_]u16{ 0x4907, 0x680A, 0xE7FE, 0xBF00 };
    const phantom_addrs = [_]u32{
        0x0200_0000, // RA8 MRAM
        0x1200_0000, // RA8 NS MRAM
        0x2200_0000, // RA8 SRAM
        0x3200_0000, // RA8 NS SRAM
        0x6800_0000, // RA8 SDRAM
        0x8000_0000, // RA8 OSPI
        0x4000_2000, // Past small MMIO window 0
        0x507E_0000, // Unaliased MMIO window 1 NS offset
        0x4000_1000, // Unknown MMIO register under .fault policy
    };
    for (phantom_addrs) |probe| {
        const bytes = makeElf(flash_base, sram_base + 0x400, &code, &.{probe});
        const ran = try runCustomElf(&bytes);
        try std.testing.expectEqual(@as(usize, 0), ran.blocks);
        try std.testing.expect(ran.cfsr & bfsr_preciserr != 0);
        try std.testing.expectEqual(probe, ran.bfar);
    }
}

test "modelled MMIO apertures and optional NS alias route while execute-never faults" {
    const Reg = struct {
        held: u32 = 0xA5A5_0001,
        fn rd(ctx: *anyopaque, _: u32, _: u3) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            return self.held;
        }
        fn wr(ctx: *anyopaque, _: u32, _: u3, v: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.held = v;
        }
    };
    var r0: Reg = .{};
    var r1: Reg = .{ .held = 0x55AA_1234 };
    var bus = registry.Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.windows = &small_mmio;
    bus.unknown = .fault;
    try bus.add(.{ .name = "B0", .base = 0x4000_0000, .size = 4, .context = &r0, .readFn = Reg.rd, .writeFn = Reg.wr });
    try bus.add(.{ .name = "B1", .base = 0x407E_0000, .size = 4, .context = &r1, .readFn = Reg.rd, .writeFn = Reg.wr });
    try std.testing.expectError(
        error.OutsideWindow,
        bus.add(.{ .name = "BAD", .base = 0x4010_0000, .size = 4, .context = &r0, .readFn = Reg.rd, .writeFn = Reg.wr }),
    );
    try std.testing.expectEqual(@as(?u32, 0xA5A5_0001), bus.tryRead(0x5000_0000, 4));
    try std.testing.expect(bus.nonsecure);
    try std.testing.expect(bus.tryWrite(0x5000_0000, 4, 0x77));
    try std.testing.expectEqual(@as(?u32, 0x77), bus.tryRead(0x4000_0000, 4));
    try std.testing.expect(!bus.nonsecure);
    try std.testing.expectEqual(@as(?u32, 0x55AA_1234), bus.tryRead(0x407E_0000, 4));
    try std.testing.expectEqual(@as(?u32, null), bus.tryRead(0x507E_0000, 4));
    try std.testing.expectEqual(@as(?u32, null), bus.tryRead(0x4000_0100, 4));

    // Branching to non-executable DATA region raises IBUSERR.
    const branch_data = [_]u16{ 0x4807, 0x4700, 0xE7FE, 0xBF00 };
    const bytes = makeElf(flash_base, sram_base + 0x400, &branch_data, &.{data_base | 1});
    try std.testing.expect((try runCustomElf(&bytes)).cfsr & bfsr_ibuserr != 0);
}

test "block cache layout survives cpu.reset and snapshot restore, and tracks 0x0000_0000 flash" {
    const ok_elf = makeElf(flash_base, sram_base + 0x400, &.{0xE7FE}, &.{});
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = &ok_elf,
        .machine = &custom_m33,
        .history_frames = 0,
    });
    defer h.deinit();
    const cache = h.primaryCpu().blocks.?;
    for ([_]u8{ 0, 1 }) |round| {
        if (round == 1) {
            try h.primaryCpu().reset(flash_base);
            cpu_snap.afterRestore(h.primaryCpu());
        }
        try h.primaryCpu().bus.write(sram_base + 0x100, &.{ 0x01, 0x20, 0x70, 0x47 });
        const first = cache.next(h.primaryCpu().bus, decode.profile.Profile.m33, sram_base + 0x100).?;
        try std.testing.expectEqual(@as(u16, 0x2001), first.instr.hw1);
        try h.primaryCpu().bus.write(ns_sram_base + 0x100, &.{ 0x09, 0x20 });
        try std.testing.expect(cache.lines.dirty);
        const updated = cache.next(h.primaryCpu().bus, decode.profile.Profile.m33, sram_base + 0x100).?;
        try std.testing.expectEqual(@as(u16, 0x2009), updated.instr.hw1);
        try std.testing.expectEqual(@as(u64, 1), cache.dropped);
    }

    const zero_regions = [_]mem_desc.Region{
        .{ .name = "FLASH0", .base = 0x0000_0000, .size = 0x1000, .track_code = true, .role = .flash },
    };
    const zero_map: mem_desc.MemoryMap = .{ .regions = &zero_regions };
    var zstore = try Store.initFor(null, &zero_map);
    defer zstore.deinit();
    try zstore.program(.none, 0x0000_0000, &.{ 0x01, 0x20, 0x70, 0x47 });
    const zcache = try std.testing.allocator.create(BlockCache);
    defer std.testing.allocator.destroy(zcache);
    zcache.init();
    try zstore.fanMut().attach(&zcache.lines);
    defer zstore.fanMut().detach(&zcache.lines);
    zcache.clear();
    const zguest: Guest = .{ .store = &zstore, .initiator = .cpu0 };
    var zgb = GuestBus.of(&zguest, true);
    _ = zcache.next(zgb.view(), decode.profile.Profile.m33, 0x0000_0000).?;
    try std.testing.expect(zcache.lines.marked(0x0000_0000));
}

test "loader rejects unmapped segments on strict map and vendor IDAU callback attributes regions" {
    var store = try Store.initFor(null, &small_map);
    defer store.deinit();
    const bad_elf = makeElf(0x0200_0000, sram_base + 0x400, &.{0xE7FE}, &.{});
    const parsed = try elf.Image.init(&bad_elf);
    const loaded = try read_image.readFor(parsed, &small_map);
    try std.testing.expectError(loader.Error.MapFailed, loader.image(.{ .store = &store }, loaded.image()));

    const ok_elf = makeElf(flash_base, sram_base + 0x400, &.{0xE7FE}, &.{});
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = &ok_elf,
        .machine = &custom_m33,
        .history_frames = 0,
    });
    defer h.deinit();
    var sau_src: SauSource = .{ .unit = &h.board().partitions, .idau = &h.board().idau };
    const attr = sau_src.source();
    try std.testing.expectEqual(@as(?u8, 10), h.board().idau.answer(flash_base).region);
    try std.testing.expectEqual(@as(?u8, 12), h.board().idau.answer(sram_base).region);
    try std.testing.expectEqual(@as(?u8, 13), h.board().idau.answer(ns_sram_base).region);
    // With SAU ALLNS set (SAU_CTRL = 2), IDAU alone decides: sram_base stays
    // Secure, ns_sram_base is Non-secure.
    h.board().partitions.ctrl = 2;
    try std.testing.expectEqual(sau_attr.State.secure, attr.of(sram_base));
    try std.testing.expectEqual(sau_attr.State.non_secure, attr.of(ns_sram_base));
    try std.testing.expectEqual(sau_attr.State.callable, attr.of(flash_base));
    try std.testing.expectEqual(sau_attr.State.non_secure, attr.of(ns_flash_base));
}
