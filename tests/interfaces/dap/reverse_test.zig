//! Covers src/interfaces/dap/reverse.zig and single-core DAP execution,
//! inspection, reverse step/continue, and restart on sole-M33 and sole-M85.
const std = @import("std");

const fixture = @import("fixture.zig");
const ra8 = @import("ra8");

const elf = ra8.board.image.elf;
const machine_mod = ra8.chip.core.machine;
const memmap = ra8.chip.core.memmap;

const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const reset_at: u32 = vectors + 0x40;
const stack: u32 = memmap.sram_base + 0x800;
const out_word: u32 = memmap.sram_base;

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

fn probeElf() [page * 2]u8 {
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
    // movs r0,#1; adds r0,#2; adds r0,#3; ldr r1,[pc,#8]; str r0,[r1]; b .; nop; nop
    const code = [_]u16{ 0x2001, 0x3002, 0x3003, 0x4902, 0x6008, 0xE7FE, 0xBF00, 0xBF00 };
    for (code, 0..) |hw, i| {
        std.mem.writeInt(u16, file[page + 0x40 + i * 2 ..][0..2], hw, .little);
    }
    std.mem.writeInt(u32, file[page + 0x50 ..][0..4], out_word, .little);
    return file;
}

fn stepOnce(adapter: *ra8.dap.adapter.Adapter, seq: u32) !void {
    const req = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"seq\":{d},\"type\":\"request\",\"command\":\"stepIn\"," ++
            "\"arguments\":{{\"threadId\":1,\"granularity\":\"instruction\"}}}}",
        .{seq},
    );
    defer std.testing.allocator.free(req);
    try fixture.expectSend(adapter, req, "\"success\":true");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try adapter.pump(&out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"reason\":\"step\"") != null);
}

test "sole-M33 DAP reports one thread, omits MVE registers, steps, rewinds and restarts" {
    const bytes = probeElf();
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m33,
        .history_frames = 8,
    });
    defer h.deinit();
    try std.testing.expectError(error.UnsupportedRegister, h.session().register(.cpu0, .vpr));
    try std.testing.expectError(error.UnsupportedRegister, h.session().setRegister(.cpu0, .vpr, 1));

    var adapter: ra8.dap.adapter.Adapter = .{
        .allocator = std.testing.allocator,
        .target = .{ .session = h.session(), .images = .{ h.image(), null } },
    };
    defer adapter.deinit();
    try fixture.expectSend(
        &adapter,
        "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}",
        "\"supportsStepBack\":true",
    );
    try fixture.expectSend(
        &adapter,
        "{\"seq\":2,\"type\":\"request\",\"command\":\"attach\",\"arguments\":{}}",
        "\"success\":true",
    );
    try fixture.expectSend(
        &adapter,
        "{\"seq\":3,\"type\":\"request\",\"command\":\"configurationDone\"}",
        "\"reason\":\"entry\"",
    );
    const threads = try fixture.send(&adapter, "{\"seq\":4,\"type\":\"request\",\"command\":\"threads\"}");
    defer std.testing.allocator.free(threads);
    try std.testing.expect(std.mem.indexOf(u8, threads, "\"name\":\"CPU0 (Cortex-M33)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, threads, "\"id\":2") == null);
    try fixture.expectSend(
        &adapter,
        "{\"seq\":5,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":2}}",
        "UnknownThread",
    );
    try checkInspectionAndBreak(&adapter, &h);
    try checkReverseAndRestart(&adapter, &h);
}

fn checkInspectionAndBreak(
    adapter: *ra8.dap.adapter.Adapter,
    h: *ra8.session.harness.Harness,
) !void {
    try fixture.expectSend(
        adapter,
        "{\"seq\":6,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}",
        "\"id\":128",
    );
    try fixture.expectSend(
        adapter,
        "{\"seq\":7,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":160}}",
        "UnknownThread",
    );
    try fixture.expectSend(
        adapter,
        "{\"seq\":8,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{\"frameId\":128}}",
        "\"variablesReference\":256",
    );
    const regs = try fixture.send(
        adapter,
        "{\"seq\":9,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{\"variablesReference\":256}}",
    );
    defer std.testing.allocator.free(regs);
    try std.testing.expect(std.mem.indexOf(u8, regs, "\"name\":\"r0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, regs, "vpr") == null);

    try stepOnce(adapter, 10);
    try stepOnce(adapter, 11);
    try stepOnce(adapter, 12);
    try fixture.expectSend(
        adapter,
        "{\"seq\":13,\"type\":\"request\",\"command\":\"setInstructionBreakpoints\"," ++
            "\"arguments\":{\"breakpoints\":[{\"instructionReference\":\"0x0200004a\"}]}}",
        "\"verified\":true",
    );
    try fixture.expectSend(
        adapter,
        "{\"seq\":14,\"type\":\"request\",\"command\":\"continue\",\"arguments\":{\"threadId\":1}}",
        "\"allThreadsContinued\":true",
    );
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try adapter.pump(&out.writer);
    try std.testing.expectEqual(reset_at + 0x0A, try h.session().register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 6), try h.guest().readWord(out_word));
}

fn checkReverseAndRestart(
    adapter: *ra8.dap.adapter.Adapter,
    h: *ra8.session.harness.Harness,
) !void {
    try fixture.expectSend(
        adapter,
        "{\"seq\":14,\"type\":\"request\",\"command\":\"stepBack\"," ++
            "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}",
        "\"reason\":\"step\"",
    );
    try std.testing.expectEqual(reset_at + 6, try h.session().register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 0), try h.guest().readWord(out_word));

    try fixture.expectSend(
        adapter,
        "{\"seq\":15,\"type\":\"request\",\"command\":\"setInstructionBreakpoints\"," ++
            "\"arguments\":{\"breakpoints\":[{\"instructionReference\":\"0x02000044\"}]}}",
        "\"verified\":true",
    );
    try fixture.expectSend(
        adapter,
        "{\"seq\":16,\"type\":\"request\",\"command\":\"reverseContinue\",\"arguments\":{\"threadId\":1}}",
        "\"reason\":\"instruction breakpoint\"",
    );
    try std.testing.expectEqual(reset_at + 4, try h.session().register(.cpu0, .pc));
    try fixture.expectSend(
        adapter,
        "{\"seq\":17,\"type\":\"request\",\"command\":\"reverseContinue\",\"arguments\":{\"threadId\":1}}",
        "\"reason\":\"step\"",
    );
    try std.testing.expectEqual(reset_at + 2, try h.session().register(.cpu0, .pc));
    try fixture.expectSend(
        adapter,
        "{\"seq\":18,\"type\":\"request\",\"command\":\"stepBack\"," ++
            "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}",
        "NotRecorded",
    );
    try fixture.expectSend(
        adapter,
        "{\"seq\":19,\"type\":\"request\",\"command\":\"restart\",\"arguments\":{}}",
        "\"reason\":\"entry\"",
    );
    try std.testing.expectEqual(reset_at, try h.session().register(.cpu0, .pc));
    try std.testing.expectEqual(@as(u32, 0), try h.session().register(.cpu0, .r0));
}

test "sole-M85 DAP reports Cortex-M85 thread identity, steps, rewinds and restarts" {
    const bytes = probeElf();
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = &sole_m85,
        .history_frames = 8,
    });
    defer h.deinit();
    try h.session().setRegister(.cpu0, .vpr, 0xABCD_0001);
    try std.testing.expectEqual(@as(u32, 0xABCD_0001), try h.session().register(.cpu0, .vpr));

    var adapter: ra8.dap.adapter.Adapter = .{
        .allocator = std.testing.allocator,
        .target = .{ .session = h.session(), .images = .{ h.image(), null } },
    };
    defer adapter.deinit();
    try fixture.connect(&adapter);
    const threads = try fixture.send(&adapter, "{\"seq\":4,\"type\":\"request\",\"command\":\"threads\"}");
    defer std.testing.allocator.free(threads);
    try std.testing.expect(std.mem.indexOf(u8, threads, "\"name\":\"CPU0 (Cortex-M85)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, threads, "\"id\":2") == null);
    try fixture.expectSend(
        &adapter,
        "{\"seq\":5,\"type\":\"request\",\"command\":\"stepIn\"," ++
            "\"arguments\":{\"threadId\":2,\"granularity\":\"instruction\"}}",
        "UnknownThread",
    );
    try stepOnce(&adapter, 6);
    try stepOnce(&adapter, 7);
    try std.testing.expectEqual(reset_at + 4, try h.session().register(.cpu0, .pc));
    try fixture.expectSend(
        &adapter,
        "{\"seq\":8,\"type\":\"request\",\"command\":\"stepBack\"," ++
            "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}",
        "\"reason\":\"step\"",
    );
    try std.testing.expectEqual(reset_at + 2, try h.session().register(.cpu0, .pc));
    try fixture.expectSend(
        &adapter,
        "{\"seq\":9,\"type\":\"request\",\"command\":\"restart\",\"arguments\":{}}",
        "\"reason\":\"entry\"",
    );
    try std.testing.expectEqual(reset_at, try h.session().register(.cpu0, .pc));
}
