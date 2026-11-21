//! Silicon-oracle and machine contract tests for `ra4t1` (alias `fpb-ra4t1`,
//! `RTK7FPA4T1S00001BE` / `R7FA4T1BB3CFM`, RA8EMU-A-71).
const cli_app = @import("cli_app");
const ra8 = @import("ra8");
const std = @import("std");

const catalog = ra8.chip.core.machine.catalog;
const clocks = ra8.chip.periph.clocks;
const cpu_mod = ra8.chip.core.cpu.cpu;
const dap_adapter = ra8.dap.adapter;
const decode = ra8.chip.core.cpu.decode;
const elf = ra8.board.image.elf;
const gdb_dispatch = ra8.gdb.rsp.dispatch;
const harness_mod = ra8.session.harness;
const memmap = ra8.chip.core.memmap;
const run_loop = ra8.session.run.loop;
const Board = ra8.board.board.Board;

const fpb_ra4t1_elf = @embedFile("../../../../fixtures/known_state/fpb_ra4t1.elf");

const expected_state_record = [11]u32{
    0x52413454, // "RA4T"
    0x410FD214, // Cortex-M33 r0p4
    0x00000000, // VTOR_S at reset
    0x00000000, // SCKSEL = HOCO
    0x00000001, // OSCSF.HOCOSF = 1
    0x40000147, // SYST_CALIB
    0x00000003, // systick_ticks
    0x00000003, // led_transitions
    0x000001C3, // PORT2.PIDR (P208, P207, P206, P201, P200)
    0x000000AC, // tx_bytes = 172
    0x00000001, // status = PASS
};

const expected_uart =
    "RA8EMU KNOWN-STATE BOOT board=fpb-ra4t1 part=r7fa4t1bb3cfm core=cortex-m33\r\n" ++
    "RA8EMU KNOWN-STATE END board=fpb-ra4t1 cpuid=410fd214 clk=hoco20m systick=3 led1=1 status=PASS\r\n";

test "ra4t1 machine descriptor carries exact RA4T1 M33 SCS, alias, and flat memory map" {
    const desc = &catalog.ra4t1;
    try std.testing.expectEqualStrings("ra4t1", desc.name);
    try std.testing.expectEqual(&catalog.ra4t1, catalog.find("ra4t1").?);
    try std.testing.expectEqual(&catalog.ra4t1, catalog.find("fpb-ra4t1").?);
    try std.testing.expect(!desc.hasSecond());
    try std.testing.expect(!desc.hasNpu());
    const core = desc.primary();
    try std.testing.expectEqual(@as(u32, 0x410F_D214), core.cpuid);
    try std.testing.expectEqual(decode.profile.Fpu.single, core.fpu);
    try std.testing.expect(!core.profile.v8_1m);
    try std.testing.expectEqual(@as(u16, 98), core.scs.irq_lines);
    try std.testing.expectEqual(@as(u4, 4), core.scs.prio_bits);
    try std.testing.expectEqual(@as(u8, 0), core.scs.sau_regions);
    try std.testing.expectEqual(@as(u8, 8), core.scs.mpu_regions_s);
    try std.testing.expectEqual(@as(u8, 8), core.scs.mpu_regions_ns);
    try std.testing.expectEqual(@as(?u4, 4), core.scs.dwt_comparators);
    try std.testing.expectEqual(@as(u5, 8), core.scs.fpb_code);
    try std.testing.expectEqual(@as(?u32, 0x0000_0000), core.scs.init_vtor);
    try std.testing.expectEqual(@as(u32, 0x4000_0147), core.scs.syst_calib);
    try std.testing.expectEqual(@as(usize, 0), desc.memory.aliases.len);
}

test "fpb_ra4t1.elf boots on ra4t1 matching bench StateRecord, 172-byte SCI9, and ROM" {
    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    board.machine = &catalog.ra4t1;

    var store: ra8.board.cpu0_store.Cpu0 = .{};
    defer store.close();
    const image = try elf.Image.init(fpb_ra4t1_elf);
    const loaded_bytes = try store.attachStore(board, image);
    const vtor = image.vectorBaseFor(board.desc().memory).?;
    try std.testing.expect(loaded_bytes > 0);
    try std.testing.expectEqual(@as(u32, 0x0000_0000), vtor);

    var sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer sink.deinit();
    const UartCapture = struct {
        buf: [256]u8 = undefined,
        len: usize = 0,
        fn onLine(ctx: ?*anyopaque, line: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(self.buf[self.len..][0..line.len], line);
            self.len += line.len;
            @memcpy(self.buf[self.len..][0..2], "\r\n");
            self.len += 2;
        }
    };
    var uart_capture: UartCapture = .{};
    board.serial.line.setSink(.{ .context = &uart_capture, .writeFn = UartCapture.onLine });
    var timebase: clocks.Clocks = .{};
    var loop: run_loop.Loop = .{};
    var loop_open = false;
    defer if (loop_open) loop.clock.deinitSnapshot();
    loop_open = true;
    try loop.run(
        &sink.writer,
        &sink.writer,
        std.testing.io,
        store.own(),
        board,
        &timebase,
        image,
        .{ .budget = 50_000 },
        vtor,
        null,
        null,
        null,
        null,
        .{},
    );

    const guest = store.own();
    for (expected_state_record, 0..) |want, i| {
        const addr: u32 = 0x2000_0100 + @as(u32, @intCast(i * 4));
        try std.testing.expectEqual(want, try guest.readWord(addr));
    }
    try std.testing.expectEqual(@as(u64, 172), board.serial.channels[9].transmitted);
    try std.testing.expectEqual(@as(u32, 2), board.serial.line.lines);
    try std.testing.expectEqual(@as(usize, 172), uart_capture.len);
    try std.testing.expectEqualStrings(expected_uart, uart_capture.buf[0..uart_capture.len]);

    var pnr: [16]u8 = undefined;
    try guest.read(0x0100_80F0, &pnr);
    try std.testing.expectEqualStrings("R7FA4T1BB3CFM   ", &pnr);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try guest.readWord(0x0100_A200));
}

test "ra4t1 faults on bit-28 aliases, OOB addresses, and read-only flash writes" {
    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    board.machine = &catalog.ra4t1;

    var store: ra8.board.cpu0_store.Cpu0 = .{};
    defer store.close();
    const image = try elf.Image.init(fpb_ra4t1_elf);
    _ = try store.attachStore(board, image);

    const primary = catalog.ra4t1.primary();
    var bus_view = ra8.chip.core.cpu.board_bus.BoardBus{
        .memory = .{ .store = .{ .store = &store.store.?, .initiator = .cpu0 } },
        .periph = &board.bus,
        .scs = .{
            .partitions = &board.partitions,
            .regions = &board.regions,
            .regions_ns = &board.regions_ns,
            .clears = &board.clears,
            .config = primary.scs,
            .systicks = primary.systicks,
            .has_security = primary.security,
            .dwt_numcomp = primary.scs.effectiveDwt(primary.profile.v8_1m),
        },
    };
    const bus = bus_view.view();
    const fault_addrs = [_]u32{
        0x1000_0000, 0x3000_0000, 0x5000_0000, 0x5011_8900, 0x0200_0000,
        0x2200_0000, 0x0004_0000, 0x0800_1000, 0x2000_A000, 0x2800_0000,
        0x4018_0000,
    };
    var scratch: [4]u8 = undefined;
    for (fault_addrs) |addr| {
        try std.testing.expectError(ra8.chip.core.cpu.bus.Error.Unmapped, bus.read(addr, &scratch));
    }
    try std.testing.expectError(ra8.chip.core.cpu.bus.Error.Unmapped, bus.write(0x0000_0000, &scratch));

    // Stepping an unmapped bit-28 read on CPU0 delivers Precise BusFault with BFAR=0x1000_0000.
    try expectBusFaultAt(&store, bus, primary.profile, 0x1000_0000);
}

test "ra4t1 core profile faults UNDEFINSTR on fp64, fp16, MVE, LOB, and CLRM" {
    const profile = catalog.ra4t1.primary().profile;
    const unsupported = [_][2]u16{
        .{ 0xEE30, 0x0B00 }, // VADD.F64 D0, D0, D0
        .{ 0xEE30, 0x0900 }, // VADD.F16 S0, S0, S0
        .{ 0xEF22, 0x0844 }, // VADD.I32 Q0, Q1, Q2 (MVE)
        .{ 0xF00F, 0xC007 }, // LE (LOB)
        .{ 0xE89F, 0x900E }, // CLRM {r1, r2, r3, ip, APSR}
    };
    for (unsupported) |hw| {
        try stepUndef(profile, hw);
    }
}

test "CLI resolves ra4t1 and alias fpb-ra4t1 and refuses --cpu1 on sole-primary machine" {
    const ok_opts = try cli_app.cli.parseWithCatalog(
        &.{ "ra8_emulator", "app.elf", "--part", "ra4t1" },
        &catalog.all,
    );
    try std.testing.expectEqual(&catalog.ra4t1, ok_opts.resolvedMachine());
    const alias_opts = try cli_app.cli.parseWithCatalog(
        &.{ "ra8_emulator", "app.elf", "--part", "fpb-ra4t1" },
        &catalog.all,
    );
    try std.testing.expectEqual(&catalog.ra4t1, alias_opts.resolvedMachine());
    try std.testing.expectError(
        error.AbsentCore,
        cli_app.cli.parseWithCatalog(
            &.{ "ra8_emulator", "app.elf", "--part", "ra4t1", "--cpu1", "cpu1.elf" },
            &catalog.all,
        ),
    );
}

test "single-thread DAP and GDB step, break, and inspect on fpb_ra4t1.elf" {
    var harness = try harness_mod.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = fpb_ra4t1_elf,
        .machine = &catalog.ra4t1,
        .device = .ra8d2,
        .history_frames = 2,
    });
    defer harness.deinit();

    var adapter: dap_adapter.Adapter = .{
        .allocator = std.testing.allocator,
        .target = .{ .session = harness.session() },
    };
    defer adapter.deinit();

    try expectDap(&adapter,
        \\{"seq":1,"type":"request","command":"initialize","arguments":{}}
    , "\"success\":true");
    try expectDap(&adapter,
        \\{"seq":2,"type":"request","command":"attach","arguments":{}}
    , "\"success\":true");
    try expectDap(&adapter,
        \\{"seq":3,"type":"request","command":"configurationDone"}
    , "\"reason\":\"entry\"");

    const threads = try sendDap(&adapter,
        \\{"seq":4,"type":"request","command":"threads"}
    );
    defer std.testing.allocator.free(threads);
    try std.testing.expect(std.mem.indexOf(u8, threads, "\"name\":\"CPU0 (Cortex-M33)\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, threads, "CPU1") == null);

    // Step and inspect registers + CPUID via GDB RSP dispatch.
    const Wall = struct {
        ns: u64 = 0,
        fn now(ctx: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ns += 1_000_000;
            return self.ns;
        }
    };
    var wall: Wall = .{};
    var target: gdb_dispatch.zig_run.Target = .{
        .session = harness.session(),
        .transport = harness.transport(),
        .wall = .{ .context = &wall, .nowFn = Wall.now },
    };
    const stub = gdb_dispatch.Dispatch{
        .machine = &harness.state.machine,
        .zig = &target,
        .session = harness.session(),
        .core = .cpu0,
    };
    var rsp: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("m1", try stub.answer("qfThreadInfo", &rsp));
    const xml = try stub.answer("qXfer:features:read:target.xml:0,400", &rsp);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<architecture>armv8-m.main</architecture>") != null);
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("s", &rsp));
    try std.testing.expectEqualStrings("14d20f41", try stub.answer("me000ed00,4", &rsp));

    const entry_pc = harness.primaryCpu().regs.pc;
    var bp_cmd: [32]u8 = undefined;
    const bp_req = try std.fmt.bufPrint(&bp_cmd, "Z0,{x},2", .{entry_pc + 2});
    try std.testing.expectEqualStrings("OK", try stub.answer(bp_req, &rsp));
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("c", &rsp));
    try std.testing.expectEqual(entry_pc + 2, harness.primaryCpu().regs.pc);
}

fn expectBusFaultAt(
    store: *ra8.board.cpu0_store.Cpu0,
    bus: ra8.chip.core.cpu.bus.Bus,
    profile: decode.profile.Profile,
    probe_addr: u32,
) !void {
    const sram: u32 = 0x2000_0200;
    const bus_handler: u32 = 0x2000_0300;
    var miss: u32 = 0;
    var fault_bus = bus;
    fault_bus.miss = &miss;
    var cpu: cpu_mod.Cpu = .{ .bus = fault_bus, .profile = profile };
    const guest = store.own();
    try guest.writeWord(sram + 0, 0x2000_9FF0); // SP
    try guest.writeWord(sram + 4, (sram + 0x40) | 1); // Reset PC
    try guest.writeWord(sram + 5 * 4, bus_handler | 1); // BusFault handler
    // ldr r0, [r0] (0x6800) at sram + 0x40
    try guest.write(sram + 0x40, &.{ 0x00, 0x68 });
    try cpu.reset(sram);
    try fault_bus.write(memmap.scb.vtor, &std.mem.toBytes(sram));
    try fault_bus.write(memmap.scb.shcsr, &std.mem.toBytes(@as(u32, 1 << 17))); // BUSFAULTENA
    cpu.regs.low[0] = probe_addr;
    _ = cpu.step();
    try std.testing.expectEqual(bus_handler, cpu.regs.pc);
    var bfar: [4]u8 = undefined;
    try fault_bus.read(memmap.scb.bfar, &bfar);
    try std.testing.expectEqual(probe_addr, std.mem.readInt(u32, &bfar, .little));
}

fn stepUndef(profile: decode.profile.Profile, hw: [2]u16) !void {
    const usage_handler: u32 = 0x2000_01C0;
    const base: u32 = 0x2000_0000;
    const code: u32 = base + 0x100;
    const ppb: u32 = 0xE000_E000;
    const Ram = struct {
        bytes: [1024]u8 = @splat(0),
        scs: [4096]u8 = @splat(0),
        fn read(ctx: *anyopaque, address: u32, into: []u8) ra8.chip.core.cpu.bus.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (address >= ppb and address - ppb + into.len <= self.scs.len) {
                @memcpy(into, self.scs[address - ppb ..][0..into.len]);
                return;
            }
            if (address < base or address - base + into.len > self.bytes.len) return error.Unmapped;
            @memcpy(into, self.bytes[address - base ..][0..into.len]);
        }
        fn write(ctx: *anyopaque, address: u32, from: []const u8) ra8.chip.core.cpu.bus.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (address >= ppb and address - ppb + from.len <= self.scs.len) {
                @memcpy(self.scs[address - ppb ..][0..from.len], from);
                return;
            }
            if (address < base or address - base + from.len > self.bytes.len) return error.Unmapped;
            @memcpy(self.bytes[address - base ..][0..from.len], from);
        }
    };
    var ram: Ram = .{};
    std.mem.writeInt(u32, ram.bytes[0..4], base + 0x400, .little);
    std.mem.writeInt(u32, ram.bytes[4..8], code | 1, .little);
    std.mem.writeInt(u32, ram.bytes[24..28], usage_handler | 1, .little);
    std.mem.writeInt(u16, ram.bytes[0x100..0x102], hw[0], .little);
    std.mem.writeInt(u16, ram.bytes[0x102..0x104], hw[1], .little);

    var cpu: cpu_mod.Cpu = .{
        .bus = .{ .ctx = &ram, .vtable = &.{ .read = Ram.read, .write = Ram.write } },
        .profile = profile,
    };
    try cpu.reset(base);
    cpu.fp.cpacr = 0x00F0_0000;
    var vtor_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &vtor_bytes, base, .little);
    try cpu.bus.write(memmap.scb.vtor, &vtor_bytes);
    var shcsr: [4]u8 = undefined;
    std.mem.writeInt(u32, &shcsr, 1 << 18, .little);
    try cpu.bus.write(memmap.scb.shcsr, &shcsr);
    _ = cpu.step();
    try std.testing.expectEqual(usage_handler, cpu.regs.pc);
    var cfsr: [4]u8 = undefined;
    try cpu.bus.read(memmap.scb.cfsr, &cfsr);
    try std.testing.expectEqual(@as(u32, 1 << 16), std.mem.readInt(u32, &cfsr, .little));
}

fn sendDap(adapter: *dap_adapter.Adapter, req: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try adapter.request(req, &out.writer);
    return std.testing.allocator.dupe(u8, out.written());
}

fn expectDap(adapter: *dap_adapter.Adapter, req: []const u8, needle: []const u8) !void {
    const got = try sendDap(adapter, req);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, needle) != null);
}
