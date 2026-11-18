//! The debugger's rewind history over a real harness (RA8EMU-1170): a stop
//! recorded into the ring at every run and step, a rewind that puts the
//! core and the store back, a step that replays forward exactly, and a ring
//! that drops the oldest frame past its stated capacity.

const std = @import("std");

const ra8 = @import("ra8");

const elf = ra8.board.image.elf;
const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";
const machine_mod = ra8.chip.core.machine;
const memmap = ra8.chip.core.memmap;

test "steps are recorded and a rewind puts the run back (RA8EMU-1170)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = elf_path, .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops) });
    defer opened.deinit();
    const session = opened.session();
    const history = opened.history();

    var pcs: [8]u32 = undefined;
    for (0..8) |i| {
        _ = try session.run(.cpu0, .step);
        pcs[i] = session.live.core.cpu.regs.pc;
    }
    try std.testing.expectEqual(@as(u32, 8), history.count);

    // Two stops back is the state the run showed then...
    try session.rewind(.cpu0, 2);
    try std.testing.expectEqual(pcs[5], session.live.core.cpu.regs.pc);

    // ...and one step forward replays exactly what followed it.
    _ = try session.run(.cpu0, .step);
    try std.testing.expectEqual(pcs[6], session.live.core.cpu.regs.pc);

    // A rewind past the recorded window refuses rather than guessing.
    try std.testing.expectError(ra8.session.api.History.Error.NotRecorded, history.frame(9));
}

test "the ring drops its oldest frame past the stated capacity (RA8EMU-1170)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = elf_path,
        .history_frames = 4,
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();
    const session = opened.session();
    const history = opened.history();

    var pcs: [6]u32 = undefined;
    for (0..6) |i| {
        _ = try session.run(.cpu0, .step);
        pcs[i] = session.live.core.cpu.regs.pc;
    }
    try std.testing.expectEqual(@as(u32, 4), history.count);

    // The first two stops fell off; the window holds the last four.
    try std.testing.expectEqual(pcs[5], (try history.frame(0)).pc);
    try std.testing.expectEqual(pcs[2], (try history.frame(3)).pc);
    try std.testing.expectError(ra8.session.api.History.Error.NotRecorded, history.frame(4));

    // Restoring the oldest live frame still lands its state exactly.
    try session.rewind(.cpu0, 3);
    try std.testing.expectEqual(pcs[2], session.live.core.cpu.regs.pc);
}

const sole_m33: machine_mod.Machine = .{
    .name = "sole-m33",
    .label = "SOLE-M33",
    .cores = .{
        .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
        }),
    },
    .part = .ra8d2,
};

const sole_m85: machine_mod.Machine = .{
    .name = "sole-m85",
    .label = "SOLE-M85",
    .cores = .{
        .primary = machine_mod.core.cortexM85(.{
            .security = true,
            .fpu = .double,
            .systicks = 2,
        }),
    },
    .part = .ra8d2,
};

fn singleCoreElf() [0x2000]u8 {
    const page: usize = 0x1000;
    const reset_at: u32 = memmap.mram_base + 0x40;
    var file: [0x2000]u8 align(@alignOf(elf.Header)) = @splat(0);
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
        .p_vaddr = memmap.mram_base,
        .p_paddr = memmap.mram_base,
        .p_filesz = 0x100,
        .p_memsz = 0x100,
        .p_flags = 5,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], memmap.sram_base + 0x800, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], reset_at | 1, .little);
    const code = [_]u16{ 0x2001, 0x3002, 0x3003, 0x4902, 0x6008, 0xE7FE, 0xBF00, 0xBF00 };
    for (code, 0..) |hw, i| {
        std.mem.writeInt(u16, file[page + 0x40 + i * 2 ..][0..2], hw, .little);
    }
    std.mem.writeInt(u32, file[page + 0x50 ..][0..4], memmap.sram_base, .little);
    return file;
}

test "sole-M33 and sole-M85 sessions save, load, reset, stepBack, reverseContinue and refuse cross-target" {
    const gpa = std.testing.allocator;
    const bytes = singleCoreElf();
    var m33_snap = std.Io.Writer.Allocating.init(gpa);
    defer m33_snap.deinit();
    var d2_snap = std.Io.Writer.Allocating.init(gpa);
    defer d2_snap.deinit();

    try verifySingleCoreHistory(gpa, &bytes, &sole_m33, &m33_snap);
    var m85_snap = std.Io.Writer.Allocating.init(gpa);
    defer m85_snap.deinit();
    try verifySingleCoreHistory(gpa, &bytes, &sole_m85, &m85_snap);

    var d2 = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &machine_mod.catalog.ra8d2,
        .history_frames = 4,
    });
    defer d2.deinit();
    _ = try d2.session().run(.cpu0, .step);
    try d2.state.files.writeTo(&d2_snap.writer);

    try expectCrossTargetRefusal(gpa, &bytes, &sole_m33, d2_snap.written());
    try expectCrossTargetRefusal(gpa, &bytes, &machine_mod.catalog.ra8d2, m33_snap.written());
    try expectCrossTargetRefusal(gpa, &bytes, &sole_m85, m33_snap.written());
}

fn verifySingleCoreHistory(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    desc: *const machine_mod.Machine,
    saved: *std.Io.Writer.Allocating,
) !void {
    const reset_at: u32 = memmap.mram_base + 0x40;
    var h = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_bytes = bytes,
        .machine = desc,
        .history_frames = 8,
    });
    defer h.deinit();
    const s = h.session();
    _ = try s.run(.cpu0, .step);
    _ = try s.run(.cpu0, .step);
    _ = try s.run(.cpu0, .step);
    _ = try s.setBreakpoint(.cpu0, .{ .address = reset_at + 0x0A });
    _ = try s.run(.cpu0, .cont);
    try std.testing.expectEqual(reset_at + 0x0A, try s.register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 6), try h.guest().readWord(memmap.sram_base));

    try h.state.files.writeTo(&saved.writer);
    try s.stepBack(.cpu0);
    try std.testing.expectEqual(reset_at + 6, try s.register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 0), try h.guest().readWord(memmap.sram_base));

    _ = try s.setBreakpoint(.cpu0, .{ .address = reset_at + 4 });
    try s.reverseContinue(.cpu0);
    try std.testing.expectEqual(reset_at + 4, try s.register(.cpu0, .pc));
    try s.reverseContinue(.cpu0);
    try std.testing.expectEqual(reset_at + 2, try s.register(.cpu0, .pc));
    try std.testing.expectError(ra8.session.api.History.Error.NotRecorded, s.stepBack(.cpu0));

    try s.resetImage();
    try std.testing.expectEqual(reset_at, try s.register(.cpu0, .pc));
    try h.state.files.readFrom(saved.written());
    try std.testing.expectEqual(reset_at + 0x0A, try s.register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 6), try h.guest().readWord(memmap.sram_base));
}

fn expectCrossTargetRefusal(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    desc: *const machine_mod.Machine,
    foreign: []const u8,
) !void {
    var h = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_bytes = bytes,
        .machine = desc,
        .history_frames = 4,
    });
    defer h.deinit();
    try h.guest().writeWord(memmap.sram_base, 0xDEAD_BEEF);
    try h.session().setRegister(.cpu0, .r0, 0x1122_3344);
    try std.testing.expectError(error.WrongPart, h.state.files.readFrom(foreign));
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), try h.guest().readWord(memmap.sram_base));
    try std.testing.expectEqual(@as(u32, 0x1122_3344), try h.session().register(.cpu0, .r0));
}
