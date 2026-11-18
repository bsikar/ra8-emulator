//! Covers src/chip/core/machine/machine.zig: a sole-M33 primary core in slot 0,
//! absent-core refusal across CLI/board/session, and single-core report hygiene
//! (RA8EMU-1342).
const cli_app = @import("cli_app");
const ra8 = @import("ra8");
const std = @import("std");

const Board = ra8.board.board.Board;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const cpuid = ra8.chip.periph.cpuid;
const dwt = ra8.chip.periph.dwt;
const elf = ra8.board.image.elf;
const machine_mod = ra8.chip.core.machine;
const main_path = cli_app.zig.run.main_path;
const memmap = ra8.chip.core.memmap;
const Parts = cli_app.parts.Parts;

const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const reset_at: u32 = vectors + 0x40;
const fault_at: u32 = vectors + 0x80;
const stack: u32 = memmap.sram_base + 0x800;
const out_word: u32 = memmap.sram_base;
const fault_word: u32 = memmap.sram_base + 4;
const ufsr_undefinstr: u32 = 1 << 16;

const sole_m33: machine_mod.Machine = .{
    .name = "test-m33",
    .label = "TEST-M33",
    .cores = .{
        .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
            .revision = .{ .variant = 0, .patch = 4 },
        }),
    },
    .part = .ra8d2,
};

const sole_m85: machine_mod.Machine = .{
    .name = "test-m85",
    .label = "TEST-M85",
    .cores = .{
        .primary = machine_mod.core.cortexM85(.{
            .security = true,
            .fpu = .double,
            .systicks = 2,
        }),
    },
    .part = .ra8d2,
};

fn baseElf() [page * 2]u8 {
    var file: [page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
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
        .p_vaddr = vectors,
        .p_paddr = vectors,
        .p_filesz = 0x100,
        .p_memsz = 0x100,
        .p_flags = 5,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], stack, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], reset_at | 1, .little);
    std.mem.writeInt(u32, file[page + 12 ..][0..4], fault_at | 1, .little);
    std.mem.writeInt(u32, file[page + 24 ..][0..4], fault_at | 1, .little);
    putHalves(file[page + 0x80 ..], &.{ 0x4902, 0x4A03, 0x6808, 0x6010, 0xE7FE, 0xBF00 });
    std.mem.writeInt(u32, file[page + 0x8C ..][0..4], 0xE000_ED28, .little);
    std.mem.writeInt(u32, file[page + 0x90 ..][0..4], fault_word, .little);
    return file;
}

fn cpuidProbeElf() [page * 2]u8 {
    var file = baseElf();
    putHalves(file[page + 0x40 ..], &.{ 0x4902, 0x4A03, 0x6808, 0x6010, 0xE7FE, 0xBF00 });
    std.mem.writeInt(u32, file[page + 0x4C ..][0..4], cpuid.address, .little);
    std.mem.writeInt(u32, file[page + 0x50 ..][0..4], out_word, .little);
    return file;
}

fn encodingProbeElf(first_hw: u16, second_hw: u16) [page * 2]u8 {
    var file = baseElf();
    putHalves(file[page + 0x40 ..], &.{ 0x2000, first_hw, second_hw, 0x4A02, 0x2077, 0x6010, 0xE7FE, 0xBF00 });
    std.mem.writeInt(u32, file[page + 0x50 ..][0..4], out_word, .little);
    return file;
}

fn putHalves(into: []u8, words: []const u16) void {
    for (words, 0..) |hw, i| {
        std.mem.writeInt(u16, into[i * 2 ..][0..2], hw, .little);
    }
}

test "sole M33 in slot 0 boots from its vector table and reports M33 CPUID and DWT" {
    const bytes = cpuidProbeElf();
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m33,
        .history_frames = 0,
    });
    defer h.deinit();
    const s = h.session();
    try std.testing.expect(s.hasCore(.cpu0));
    try std.testing.expect(!s.hasCore(.cpu1));
    try std.testing.expectEqual(@as(?machine_mod.Core, null), s.coreInfo(.cpu1));
    try std.testing.expectEqual(@as(u32, 0x410F_D214), s.coreInfo(.cpu0).?.cpuid);
    try std.testing.expectEqual(@as(u4, 4), (try s.machine(.cpu0)).dwt.numcomp);
    try std.testing.expectEqual(@as(u32, 0), try h.guest().readWord(memmap.sau.type_));
    try std.testing.expectEqual(reset_at, try s.register(.cpu0, .pc));
    try s.setRunBudget(.cpu0, 16);
    _ = try s.run(.cpu0, .cont);
    try std.testing.expectEqual(@as(u32, 0x410F_D214), try h.guest().readWord(out_word));
    const ctrl = try h.guest().readWord(dwt.base);
    try std.testing.expectEqual(@as(u32, 4) << dwt.ctrl_bits.numcomp_shift, ctrl & dwt.ctrl_bits.numcomp_mask);
}

test "sole M33 in slot 0 rejects MVE, LOB and Armv8.1-M encodings that M85 runs" {
    const cases = [_][2]u16{
        .{ 0xEA52, 0x038F }, // MVE: lsll r2, r3, #2
        .{ 0xF040, 0xE001 }, // LOB: dls lr, r0
        .{ 0xEA51, 0x8002 }, // v8.1-M: csel r0, r1, r2, eq
    };
    for (cases) |pair| {
        const bytes = encodingProbeElf(pair[0], pair[1]);
        var m33 = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
            .elf_bytes = &bytes,
            .machine = &sole_m33,
            .history_frames = 0,
        });
        defer m33.deinit();
        try m33.session().setRunBudget(.cpu0, 24);
        _ = try m33.session().run(.cpu0, .cont);
        try std.testing.expectEqual(@as(u32, 0), try m33.guest().readWord(out_word));
        try std.testing.expectEqual(ufsr_undefinstr, (try m33.guest().readWord(fault_word)) & ufsr_undefinstr);

        var m85 = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
            .elf_bytes = &bytes,
            .machine = &sole_m85,
            .history_frames = 0,
        });
        defer m85.deinit();
        try m85.session().setRunBudget(.cpu0, 24);
        _ = try m85.session().run(.cpu0, .cont);
        try std.testing.expectEqual(@as(u32, 0x77), try m85.guest().readWord(out_word));
        try std.testing.expectEqual(@as(u32, 0), try m85.guest().readWord(fault_word));
    }
}

test "plain run loop executes sole M33 in slot 0 as M33 and rejects MVE" {
    const bytes = encodingProbeElf(0xEA52, 0x038F);
    const loaded = try elf.Image.init(&bytes);
    var board = Board.init(std.testing.allocator);
    defer board.deinit();
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    const options: cli_app.cli.Options = .{
        .path = "m33.elf",
        .machine = &sole_m33,
        .instructions = 24,
    };
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
        vectors,
        null,
        null,
        .{},
    );
    try std.testing.expectEqual(@as(u32, 0), try cpu0.own().readWord(out_word));
    try std.testing.expectEqual(ufsr_undefinstr, (try cpu0.own().readWord(fault_word)) & ufsr_undefinstr);
}

test "sole M85 refuses second-core bringup and omits CPU1 from text and JSON reports" {
    const bytes = cpuidProbeElf();
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m85,
        .history_frames = 0,
    });
    defer h.deinit();
    var cpu1: ra8.session.cpu1.bringup.Cpu1 = .{};
    try std.testing.expectError(error.AbsentCore, cpu1.openBytes(std.testing.allocator, &h, &bytes));
    try std.testing.expect(!h.session().hasCore(.cpu1));

    const loaded = try elf.Image.init(&bytes);
    for ([_]bool{ false, true }) |as_json| {
        var board = Board.init(std.testing.allocator);
        defer board.deinit();
        var cpu0: Cpu0 = .{};
        defer cpu0.close();
        var parts = Parts{};
        const options: cli_app.cli.Options = .{
            .path = "m85.elf",
            .machine = &sole_m85,
            .instructions = 16,
            .report_json = as_json,
            .cpu_load = as_json,
        };
        try main_path.fit(&board, std.testing.allocator, std.testing.io, options);
        try std.testing.expect(board.transfers.twin == null);
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
            vectors,
            null,
            null,
            .{},
        );
        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, out.written(), "CPU1"));
        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, out.written(), "cpu1"));
        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, out.written(), "dtc1"));
        try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, out.written(), "DTC1"));
    }
}

test "CLI selects machine by name, refuses unknown names and refuses --cpu1 on single-core" {
    const custom = [_]*const machine_mod.Machine{
        &machine_mod.catalog.ra8d2,
        &machine_mod.catalog.ra8p1,
        &sole_m33,
        &sole_m85,
    };
    const picked = try cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--part", "test-m33" }, &custom);
    try std.testing.expectEqual(&sole_m33, picked.resolvedMachine());
    try std.testing.expectError(
        error.UnknownPart,
        cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--part", "nope" }, &custom),
    );
    try std.testing.expectError(
        error.AbsentCore,
        cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--part", "test-m85", "--cpu1", "b.elf" }, &custom),
    );
    try std.testing.expectError(
        error.AbsentCore,
        cli_app.cli.parseWithCatalog(&.{ "emu", "a.elf", "--cpu1", "b.elf", "--part", "test-m33" }, &custom),
    );
    const dual = try cli_app.cli.parseWithCatalog(
        &.{ "emu", "a.elf", "--part", "ra8d2", "--cpu1", "b.elf" },
        &custom,
    );
    try std.testing.expectEqualStrings("b.elf", dual.cpu1_path.?);
}
