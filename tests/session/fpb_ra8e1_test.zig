//! Silicon-oracle parity, fault boundary, --cpu1 refusal, and single-core
//! GDB/DAP debugger tests for `fpb-ra8e1` (`R01UH1129EJ0110` / `R20UT5474EG0100`).
const cli_app = @import("cli_app");
const ra8 = @import("ra8");
const std = @import("std");

const Board = ra8.board.board.Board;
const catalog = ra8.chip.core.machine.catalog;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const elf = ra8.board.image.elf;
const harness = ra8.session.harness;
const main_path = cli_app.zig.run.main_path;
const Parts = cli_app.parts.Parts;
const sci = ra8.chip.periph.sci;

const known_elf = @embedFile("../fixtures/known_state/fpb_ra8e1.elf");

const expected_uart =
    "RA8EMU KNOWN-STATE BOOT board=fpb-ra8e1 part=r7fa8e1afdcfb core=cortex-m85\r\n" ++
    "RA8EMU KNOWN-STATE END board=fpb-ra8e1 cpuid=410fd232 clk=hoco48m systick=3 led1=1 status=PASS\r\n";

const expected_state = [_]u32{
    0x5241_3845,
    0x410F_D232,
    0x0200_0000,
    0x0000_0000,
    0x0000_0001,
    0x0000_270F,
    0x0000_0003,
    0x0000_0003,
    0x0000_0010,
    0x0000_00AC,
    0x0000_0001,
};

const page: usize = 0x1000;
const flash_base: u32 = 0x0200_0000;
const sram_base: u32 = 0x2206_0000;
const bfsr_preciserr: u32 = 1 << 9;

const UartCapture = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    fn tap(self: *UartCapture) sci.Tap {
        return .{ .ctx = self, .sent = onByte };
    }

    fn onByte(ctx: *anyopaque, channel: usize, byte: u8) void {
        const self: *UartCapture = @ptrCast(@alignCast(ctx));
        if (channel != sci.event.ra8e1_console_channel or self.len == self.buf.len) return;
        self.buf[self.len] = byte;
        self.len += 1;
    }
};

var dummy_wall_ns: u64 = 0;

fn wallNow(_: *anyopaque) u64 {
    dummy_wall_ns += 1_000_000;
    return dummy_wall_ns;
}

fn faultProbeElf(probe_addr: u32) [page * 2]u8 {
    var file: [page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    const reset_at = flash_base + 0x40;
    const fault_at = flash_base + 0x80;
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
        .p_vaddr = flash_base,
        .p_paddr = flash_base,
        .p_filesz = 0x100,
        .p_memsz = 0x100,
        .p_flags = 5,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], sram_base + 0x1000, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], reset_at | 1, .little);
    std.mem.writeInt(u32, file[page + 12 ..][0..4], fault_at | 1, .little);
    std.mem.writeInt(u32, file[page + 20 ..][0..4], fault_at | 1, .little);
    // Reset: ldr r1, [pc, #4]; ldr r0, [r1]; b .
    for ([_]u16{ 0x4901, 0x6808, 0xE7FE, 0xBF00 }, 0..) |hw, i| {
        std.mem.writeInt(u16, file[page + 0x40 + i * 2 ..][0..2], hw, .little);
    }
    std.mem.writeInt(u32, file[page + 0x48 ..][0..4], probe_addr, .little);
    // Fault: ldr r0, [pc, #12]; ldr r1, [pc, #16]; str r2/r0; ldr r0, [pc, #12]; str ...
    // Read CFSR (0xE000_ED28) -> SRAM+0, BFAR (0xE000_ED38) -> SRAM+4, then spin.
    for ([_]u16{ 0x4803, 0x4904, 0x6800, 0x6008, 0x4803, 0x6800, 0x6048, 0xE7FE }, 0..) |hw, i| {
        std.mem.writeInt(u16, file[page + 0x80 + i * 2 ..][0..2], hw, .little);
    }
    std.mem.writeInt(u32, file[page + 0x90 ..][0..4], 0xE000_ED28, .little);
    std.mem.writeInt(u32, file[page + 0x94 ..][0..4], sram_base, .little);
    std.mem.writeInt(u32, file[page + 0x98 ..][0..4], 0xE000_ED38, .little);
    return file;
}

fn runFaultProbe(bytes: []const u8) !struct { cfsr: u32, bfar: u32 } {
    const loaded = try elf.Image.init(bytes);
    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    const parts = try std.testing.allocator.create(Parts);
    defer std.testing.allocator.destroy(parts);
    parts.* = .{};
    defer parts.deinit();
    const options: cli_app.cli.Options = .{
        .path = "probe.elf",
        .machine = &catalog.ra8e1,
        .instructions = 32,
    };
    try main_path.fit(board, std.testing.allocator, std.testing.io, options);
    _ = try main_path.prepare(&cpu0, board, std.testing.io, loaded, parts, options);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    _ = try cli_app.zig.run.run(
        &out.writer,
        std.testing.io,
        cpu0.own(),
        board,
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
    };
}

fn expectGdb(stub: *const ra8.gdb.rsp.dispatch.Dispatch, req: []const u8, want: []const u8) !void {
    var out: [512]u8 = undefined;
    try std.testing.expectEqualStrings(want, try stub.answer(req, &out));
}

fn dapCall(
    adapter: *ra8.dap.adapter.Adapter,
    req: []const u8,
    needle: []const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try adapter.request(req, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), needle) != null);
    return out.toOwnedSlice();
}

fn dapRequest(adapter: *ra8.dap.adapter.Adapter, req: []const u8, needle: []const u8) !void {
    const owned = try dapCall(adapter, req, needle);
    std.testing.allocator.free(owned);
}

fn jsonU32(text: []const u8, key: []const u8) !u32 {
    const start = std.mem.indexOf(u8, text, key) orelse return error.MissingField;
    var end = start + key.len;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    return std.fmt.parseInt(u32, text[start + key.len .. end], 10);
}

test "silicon-oracle boot emits exact 172-byte UART and 11-word StateRecord at 0x2206_0100" {
    try std.testing.expectEqual(@as(usize, 172), expected_uart.len);
    var h = try harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = known_elf,
        .machine = &catalog.ra8e1,
        .history_frames = 0,
    });
    defer h.deinit();
    var capture: UartCapture = .{};
    h.board().serial.tap = capture.tap();

    const s = h.session();
    s.history = null;
    try s.setRunBudget(.cpu0, 100_000);
    _ = try s.run(.cpu0, .cont);

    try std.testing.expectEqual(@as(usize, 172), capture.len);
    try std.testing.expectEqualStrings(expected_uart, capture.buf[0..capture.len]);
    try std.testing.expectEqual(@as(u64, 48_000_000), h.board().time.base.hz);

    for (expected_state, 0..) |want, idx| {
        const addr: u32 = 0x2206_0100 + @as(u32, @intCast(idx * 4));
        try std.testing.expectEqual(want, try h.guest().readWord(addr));
    }
    try std.testing.expectEqual(@as(u32, 2), try h.primaryCpu().bus.readWord(0xE000_E004));
    try std.testing.expectEqual(@as(u32, 0x0000_270F), try h.primaryCpu().bus.readWord(0xE000_E01C));
}

test "fpb-ra8e1 faults with BFSR.PRECISERR at unmapped RAM, gap, SDRAM, and absent MMIO" {
    const probes = [_]u32{ 0x2200_0000, 0x2000_4000, 0x6800_0000, 0x4035_8800, 0x4014_0000 };
    for (probes) |addr| {
        const bytes = faultProbeElf(addr);
        const ran = try runFaultProbe(&bytes);
        try std.testing.expect(ran.cfsr & bfsr_preciserr != 0);
        try std.testing.expectEqual(addr, ran.bfar);
    }
}

test "single-core ra8e1 and fpb-ra8e1 alias refuse --cpu1 across CLI and Harness" {
    try std.testing.expectError(
        error.AbsentCore,
        cli_app.cli.parse(&.{ "ra8_emulator", "a.elf", "--part", "ra8e1", "--cpu1", "b.elf" }),
    );
    try std.testing.expectError(
        error.AbsentCore,
        cli_app.cli.parse(&.{ "ra8_emulator", "a.elf", "--part", "fpb-ra8e1", "--cpu1", "b.elf" }),
    );
    var h = try harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = known_elf,
        .machine = &catalog.ra8e1,
        .history_frames = 0,
    });
    defer h.deinit();
    var cpu1: ra8.session.cpu1.bringup.Cpu1 = .{};
    try std.testing.expectError(error.AbsentCore, cpu1.openBytes(std.testing.allocator, &h, known_elf));
    try std.testing.expect(!h.session().hasCore(.cpu1));
}

fn expectSingleThreadDap(s: *ra8.session.api.Session, bp_target: u32) !void {
    const init_req = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}";
    const attach_req = "{\"seq\":2,\"type\":\"request\",\"command\":\"attach\",\"arguments\":{}}";
    const done_req = "{\"seq\":3,\"type\":\"request\",\"command\":\"configurationDone\"}";
    const threads_req = "{\"seq\":4,\"type\":\"request\",\"command\":\"threads\"}";
    const step_req =
        "{\"seq\":5,\"type\":\"request\",\"command\":\"stepIn\"," ++
        "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}";
    const stack_req = "{\"seq\":6,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}";

    var adapter: ra8.dap.adapter.Adapter = .{
        .allocator = std.testing.allocator,
        .target = .{ .session = s },
    };
    defer adapter.deinit();
    try dapRequest(&adapter, init_req, "\"success\":true");
    try dapRequest(&adapter, attach_req, "\"success\":true");
    try dapRequest(&adapter, done_req, "\"reason\":\"entry\"");
    try dapRequest(&adapter, threads_req, "\"name\":\"CPU0 (Cortex-M85)\"");

    var req_buf: [192]u8 = undefined;
    const bp_req = try std.fmt.bufPrint(
        &req_buf,
        "{{\"seq\":9,\"type\":\"request\",\"command\":\"setInstructionBreakpoints\"," ++
            "\"arguments\":{{\"breakpoints\":[{{\"instructionReference\":\"0x{x}\"}}]}}}}",
        .{bp_target},
    );
    try dapRequest(&adapter, step_req, "\"success\":true");
    var dap_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer dap_out.deinit();
    try adapter.pump(&dap_out.writer);
    try std.testing.expect(std.mem.indexOf(u8, dap_out.written(), "\"reason\":\"step\"") != null);
    try dapRequest(&adapter, bp_req, "\"verified\":true");

    const stack_res = try dapCall(&adapter, stack_req, "\"instructionPointerReference\":");
    defer std.testing.allocator.free(stack_res);
    const frame_id = try jsonU32(stack_res, "\"id\":");
    const scopes_req = try std.fmt.bufPrint(
        &req_buf,
        "{{\"seq\":7,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{{\"frameId\":{d}}}}}",
        .{frame_id},
    );
    const scopes_res = try dapCall(&adapter, scopes_req, "\"name\":\"Registers\"");
    defer std.testing.allocator.free(scopes_res);
    const vars_ref = try jsonU32(scopes_res, "\"variablesReference\":");
    const vars_req = try std.fmt.bufPrint(
        &req_buf,
        "{{\"seq\":8,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{{\"variablesReference\":{d}}}}}",
        .{vars_ref},
    );
    try dapRequest(&adapter, vars_req, "\"name\":\"r0\"");
}

test "public single-thread GDB RSP and DAP inspect, break, and step on ra8e1" {
    var h = try harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = known_elf,
        .machine = &catalog.ra8e1,
        .history_frames = 4,
    });
    defer h.deinit();
    const s = h.session();
    const entry_pc = try s.register(.cpu0, .pc);
    var plane: ra8.session.transport.Transport = .{ .session = s };
    var target: ra8.gdb.rsp.dispatch.zig_run.Target = .{
        .session = s,
        .transport = &plane,
        .wall = .{ .context = &dummy_wall_ns, .nowFn = wallNow },
    };
    const stub: ra8.gdb.rsp.dispatch.Dispatch = .{ .zig = &target };

    try expectGdb(&stub, "qfThreadInfo", "m1");
    try expectGdb(&stub, "qsThreadInfo", "l");
    try expectGdb(&stub, "qC", "QC1");
    try expectGdb(&stub, "T2", "E00");
    try expectGdb(&stub, "Hg2", "E00");
    try expectGdb(&stub, "m030080f0,10", "52374641384531414644434642202020");
    try expectGdb(&stub, "s", "T05thread:1;");
    const after_step = try s.register(.cpu0, .pc);
    try std.testing.expect(after_step != entry_pc);
    try expectGdb(&stub, "s", "T05thread:1;");
    const bp_target = try s.register(.cpu0, .pc);
    var z_buf: [32]u8 = undefined;
    const z_set = try std.fmt.bufPrint(&z_buf, "Z0,{x},2", .{bp_target});
    try expectGdb(&stub, z_set, "OK");
    try s.setRegister(.cpu0, .pc, after_step);
    try expectGdb(&stub, "c", "T05thread:1;");
    try std.testing.expectEqual(bp_target, try s.register(.cpu0, .pc));
    const z_clr = try std.fmt.bufPrint(&z_buf, "z0,{x},2", .{bp_target});
    try expectGdb(&stub, z_clr, "OK");

    try expectSingleThreadDap(s, bp_target);
}
