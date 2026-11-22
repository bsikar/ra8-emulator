//! Generic single-core Cortex-M55 machine session, CLI, report, DAP, GDB, and
//! snapshot coverage.
const cli_app = @import("cli_app");
const ra8 = @import("ra8");
const std = @import("std");

const Adapter = ra8.dap.adapter.Adapter;
const Board = ra8.board.board.Board;
const board_snap = ra8.board.snapshot.board;
const catalog = ra8.chip.core.machine.catalog;
const cli = cli_app.cli;
const cli_main = cli_app.zig.run.main_path;
const cli_run = cli_app.zig.run;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const elf = ra8.board.image.elf;
const gdb_dispatch = ra8.gdb.rsp.dispatch;
const harness_mod = ra8.session.harness;
const json_run = cli_app.report.json.run;
const Machine = ra8.chip.core.machine.Machine;
const part_report = cli_app.report.part;
const Parts = cli_app.parts.Parts;
const RunPolicy = ra8.session.run.policy.RunPolicy;
const snap_file = ra8.snapshot.file;
const Store = ra8.chip.core.cpu.memory.store.Store;
const symbols = ra8.session.symbols;
const testing = std.testing;
const transport_mod = ra8.session.transport;
const wiring = ra8.board.wiring;

const cortex_m55_elf = @embedFile("../fixtures/generic_machines/cortex_m55.elf");

fn wallNow(_: *anyopaque) u64 {
    return 0;
}

fn openHarness(frames: u32) !harness_mod.Harness {
    var h = try harness_mod.open(testing.allocator, testing.io, .{
        .elf_bytes = cortex_m55_elf,
        .machine = &catalog.cortex_m55,
        .history_frames = frames,
    });
    if (frames == 0) h.session().history = null;
    return h;
}

fn makeBoard(gpa: std.mem.Allocator) !*Board {
    const board = try gpa.create(Board);
    board.* = Board.init(gpa);
    return board;
}

fn destroyBoard(gpa: std.mem.Allocator, board: *Board) void {
    board.deinit();
    gpa.destroy(board);
}

fn makeParts(gpa: std.mem.Allocator) !*Parts {
    const parts = try gpa.create(Parts);
    parts.* = .{};
    return parts;
}

fn destroyParts(gpa: std.mem.Allocator, parts: *Parts) void {
    parts.deinit();
    gpa.destroy(parts);
}

fn makeCpu0(gpa: std.mem.Allocator) !*Cpu0 {
    const cpu0 = try gpa.create(Cpu0);
    cpu0.* = .{};
    return cpu0;
}

fn destroyCpu0(gpa: std.mem.Allocator, cpu0: *Cpu0) void {
    cpu0.close();
    gpa.destroy(cpu0);
}

fn dapCall(adapter: *Adapter, payload: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    try adapter.request(payload, &out.writer);
    return try out.toOwnedSlice();
}

fn dapExpect(adapter: *Adapter, payload: []const u8, needle: []const u8) !void {
    const reply = try dapCall(adapter, payload);
    defer testing.allocator.free(reply);
    try testing.expect(std.mem.indexOf(u8, reply, needle) != null);
}

fn dapBoot(adapter: *Adapter) !void {
    try dapExpect(
        adapter,
        "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}",
        "\"supportsStepBack\":true",
    );
    try dapExpect(
        adapter,
        "{\"seq\":2,\"type\":\"request\",\"command\":\"launch\",\"arguments\":{\"stopOnEntry\":true}}",
        "\"event\":\"initialized\"",
    );
    try dapExpect(
        adapter,
        "{\"seq\":3,\"type\":\"request\",\"command\":\"setExceptionBreakpoints\",\"arguments\":{\"filters\":[]}}",
        "\"success\":true",
    );
    try dapExpect(
        adapter,
        "{\"seq\":4,\"type\":\"request\",\"command\":\"configurationDone\",\"arguments\":{}}",
        "\"reason\":\"entry\"",
    );
}

fn dapPumpUntilStopped(adapter: *Adapter) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    for (0..128) |_| {
        try adapter.pump(&out.writer);
        if (std.mem.indexOf(u8, out.written(), "\"event\":\"stopped\"") != null) {
            return try out.toOwnedSlice();
        }
    }
    return error.DidNotStop;
}

const WiredBoard = struct {
    gpa: std.mem.Allocator,
    store: *Store,
    board: *Board,

    fn open(gpa: std.mem.Allocator, desc: *const Machine) !WiredBoard {
        const store = try gpa.create(Store);
        errdefer gpa.destroy(store);
        store.* = try Store.initFor(null, desc.memory);
        errdefer store.deinit();
        const board = try makeBoard(gpa);
        errdefer destroyBoard(gpa, board);
        board.machine = desc;
        board.part = desc.part;
        try wiring.attachBlocks(board, .{ .store = store });
        return .{ .gpa = gpa, .store = store, .board = board };
    }

    fn close(self: *WiredBoard) void {
        destroyBoard(self.gpa, self.board);
        self.store.deinit();
        self.gpa.destroy(self.store);
    }
};

fn snapshotFor(gpa: std.mem.Allocator, desc: *const Machine) ![]u8 {
    var wb = try WiredBoard.open(gpa, desc);
    defer wb.close();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try snap_file.writeHeader(&out.writer);
    try board_snap.save(wb.board, &out.writer);
    return try out.toOwnedSlice();
}

fn expectSnapshotLoads(gpa: std.mem.Allocator, desc: *const Machine, bytes: []const u8) !void {
    var wb = try WiredBoard.open(gpa, desc);
    defer wb.close();
    try board_snap.load(wb.board, bytes);
}

fn expectSnapshotWrongPart(gpa: std.mem.Allocator, desc: *const Machine, bytes: []const u8) !void {
    var wb = try WiredBoard.open(gpa, desc);
    defer wb.close();
    try testing.expectError(error.WrongPart, board_snap.load(wb.board, bytes));
}

test "CLI parses --part cortex-m55 and refuses --cpu1 with AbsentCore" {
    const by_part = try cli.parse(&.{ "ra8_emulator", "fw.elf", "--part", "cortex-m55" });
    try testing.expect(by_part.part_set);
    try testing.expectEqual(&catalog.cortex_m55, by_part.resolvedMachine());

    const by_device = try cli.parse(&.{ "ra8_emulator", "fw.elf", "--device", "cortex-m55" });
    try testing.expectEqual(&catalog.cortex_m55, by_device.resolvedMachine());

    try testing.expectError(
        error.AbsentCore,
        cli.parse(&.{ "ra8_emulator", "c0.elf", "--part", "cortex-m55", "--cpu1", "c1.elf" }),
    );
}

test "CLI text and JSON reports identify Cortex-M55 and --until catches ITM line" {
    try testing.expect(part_report.shownMachine(&catalog.cortex_m55));
    var line_buf: [256]u8 = undefined;
    const line = try part_report.lineMachine(&line_buf, &catalog.cortex_m55);
    try testing.expect(std.mem.startsWith(u8, line, "PART: Cortex-M55 FLASH 256 KB"));
    try testing.expect(std.mem.indexOf(u8, line, "CPU0 Cortex-M55") != null);

    {
        var h = try openHarness(0);
        defer h.deinit();
        var json_out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer json_out.deinit();
        try json_run.document(&json_out.writer, h.board(), .{ .engine = "zig", .elapsed = 10 });
        try testing.expect(std.mem.indexOf(u8, json_out.written(), "\"part\":\"Cortex-M55\"") != null);
        try testing.expect(std.mem.indexOf(u8, json_out.written(), "\"cpu1\"") == null);
    }

    {
        const board = try makeBoard(testing.allocator);
        defer destroyBoard(testing.allocator, board);
        const parts = try makeParts(testing.allocator);
        defer destroyParts(testing.allocator, parts);
        const cpu0 = try makeCpu0(testing.allocator);
        defer destroyCpu0(testing.allocator, cpu0);

        const opt = try cli.parse(&.{
            "ra8_emulator",
            "cortex_m55.elf",
            "--part",
            "cortex-m55",
            "--until",
            "GENERIC M55 PASS",
        });
        try cli_main.fit(board, testing.allocator, testing.io, opt);
        var asked: RunPolicy = .{};
        asked.attach(board);
        const image = try elf.Image.init(cortex_m55_elf);
        _ = try cli_main.prepare(cpu0, board, testing.io, image, parts, opt);
        const vbase = try cli_main.vectorBaseFor(image, board.desc().memory);
        var run_out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer run_out.deinit();
        const code = try cli_run.run(
            &run_out.writer,
            testing.io,
            cpu0.own(),
            board,
            &parts.timebase,
            image,
            opt,
            vbase,
            null,
            parts.tap.waiting(),
            .{ .policy = &asked },
        );
        try testing.expectEqual(@as(u8, 0), code);
        try testing.expect(parts.tap.waiting().?.reached);
        try testing.expect(std.mem.indexOf(u8, run_out.written(), "PART: Cortex-M55 FLASH 256 KB") != null);
    }
}

test "Session coreInfo, single-core refusal, and VPR register access on Cortex-M55" {
    var h = try openHarness(0);
    defer h.deinit();

    const info = h.session().coreInfo(.cpu0).?;
    try testing.expectEqualStrings("Cortex-M55", info.name);
    try testing.expect(info.profile.v8_1m);
    try testing.expect(info.profile.mve);
    try testing.expect(!info.profile.pacbti);
    try testing.expectEqual(.double, info.profile.fpu);
    try testing.expect(!h.session().hasCore(.cpu1));
    try testing.expectEqual(@as(?@TypeOf(info), null), h.session().coreInfo(.cpu1));
    try testing.expectError(error.CoreNotAttached, h.session().select(.cpu1));
    try testing.expectError(error.CoreNotAttached, h.session().view(.cpu1));
    try testing.expectError(error.CoreNotAttached, h.session().run(.cpu1, .step));

    _ = try h.session().register(.cpu0, .vpr);
    try h.session().setRegister(.cpu0, .vpr, 0x0000_0005);
    try testing.expectEqual(@as(u32, 0x0000_0005), try h.session().register(.cpu0, .vpr));
}

test "DAP presents one Cortex-M55 thread, supports breakpoints/stepBack/restart, refuses thread 2" {
    var h = try openHarness(8);
    defer h.deinit();
    var adapter: Adapter = .{
        .allocator = testing.allocator,
        .target = .{ .session = h.session(), .images = .{ h.image(), null } },
    };
    defer adapter.deinit();
    try dapBoot(&adapter);

    const threads = try dapCall(&adapter, "{\"seq\":5,\"type\":\"request\",\"command\":\"threads\",\"arguments\":{}}");
    defer testing.allocator.free(threads);
    try testing.expect(std.mem.indexOf(u8, threads, "\"CPU0 (Cortex-M55)\"") != null);
    try testing.expect(std.mem.indexOf(u8, threads, "\"id\":2") == null);

    const bp_addr = symbols.addressOf(h.image(), "SysTick_Handler").?;
    var bp_buf: [160]u8 = undefined;
    const bp_req = try std.fmt.bufPrint(
        &bp_buf,
        "{{\"seq\":6,\"type\":\"request\",\"command\":\"setInstructionBreakpoints\"," ++
            "\"arguments\":{{\"breakpoints\":[{{\"instructionReference\":\"0x{x}\"}}]}}}}",
        .{bp_addr},
    );
    try dapExpect(&adapter, bp_req, "\"verified\":true");
    try dapExpect(
        &adapter,
        "{\"seq\":7,\"type\":\"request\",\"command\":\"continue\",\"arguments\":{\"threadId\":1}}",
        "\"allThreadsContinued\":true",
    );
    const hit_ev = try dapPumpUntilStopped(&adapter);
    defer testing.allocator.free(hit_ev);
    try testing.expect(std.mem.indexOf(u8, hit_ev, "\"instruction breakpoint\"") != null);

    try dapExpect(
        &adapter,
        "{\"seq\":8,\"type\":\"request\",\"command\":\"stepIn\"," ++
            "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}",
        "\"success\":true",
    );
    const step_ev = try dapPumpUntilStopped(&adapter);
    defer testing.allocator.free(step_ev);
    try testing.expect(std.mem.indexOf(u8, step_ev, "\"reason\":\"step\"") != null);

    try dapExpect(
        &adapter,
        "{\"seq\":9,\"type\":\"request\",\"command\":\"stepBack\"," ++
            "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}",
        "\"reason\":\"step\"",
    );
    try dapExpect(
        &adapter,
        "{\"seq\":10,\"type\":\"request\",\"command\":\"restart\",\"arguments\":{}}",
        "\"reason\":\"entry\"",
    );

    for ([_][]const u8{ "pause", "stepIn", "stackTrace" }, 11..) |cmd, seq| {
        var err_buf: [128]u8 = undefined;
        const req = try std.fmt.bufPrint(
            &err_buf,
            "{{\"seq\":{d},\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{{\"threadId\":2}}}}",
            .{ seq, cmd },
        );
        try dapExpect(&adapter, req, "\"success\":false");
    }
}

test "GDB RSP reports armv8.1-m.main, thread m1 only, breakpoints/run/step, and refuses thread 2" {
    var h = try openHarness(0);
    defer h.deinit();
    var dummy: u8 = 0;
    var target: gdb_dispatch.zig_run.Target = .{
        .session = h.session(),
        .wall = .{ .context = &dummy, .nowFn = wallNow },
    };
    const dispatcher: gdb_dispatch.Dispatch = .{ .zig = &target };
    var out: [4096]u8 = undefined;

    const xml = try dispatcher.answer("qXfer:features:read:target.xml:0,fff", &out);
    try testing.expect(std.mem.indexOf(u8, xml, "<architecture>armv8.1-m.main</architecture>") != null);
    try testing.expectEqualStrings("m1", try dispatcher.answer("qfThreadInfo", &out));
    try testing.expectEqualStrings("l", try dispatcher.answer("qsThreadInfo", &out));
    try testing.expectEqualStrings("QC1", try dispatcher.answer("qC", &out));

    const extra_hex = try dispatcher.answer("qThreadExtraInfo,1", &out);
    var extra_buf: [64]u8 = undefined;
    const extra = try std.fmt.hexToBytes(&extra_buf, extra_hex);
    try testing.expectEqualStrings("CPU0 (Cortex-M55, armv8.1-m.main)", extra);

    try testing.expectEqualStrings("OK", try dispatcher.answer("T1", &out));
    for ([_][]const u8{ "T2", "Hg2", "Hc2", "vCont;c:2" }) |req| {
        try testing.expectEqualStrings("E00", try dispatcher.answer(req, &out));
    }

    const bp_addr = symbols.addressOf(h.image(), "SysTick_Handler").? & ~@as(u32, 1);
    var cmd_buf: [64]u8 = undefined;
    const z0 = try std.fmt.bufPrint(&cmd_buf, "Z0,{x},2", .{bp_addr});
    try testing.expectEqualStrings("OK", try dispatcher.answer(z0, &out));
    try testing.expect(std.mem.startsWith(u8, try dispatcher.answer("c", &out), "T05thread:1;"));
    try testing.expectEqual(@as(usize, gdb_dispatch.registers.len * 8), (try dispatcher.answer("g", &out)).len);
    const clear = try std.fmt.bufPrint(&cmd_buf, "z0,{x},2", .{bp_addr});
    try testing.expectEqualStrings("OK", try dispatcher.answer(clear, &out));
    try testing.expect(std.mem.startsWith(u8, try dispatcher.answer("s", &out), "T05thread:1;"));
}

test "Named board snapshot refuses WrongPart across cortex-m55 and shipped machines" {
    const m55_snap = try snapshotFor(testing.allocator, &catalog.cortex_m55);
    defer testing.allocator.free(m55_snap);

    const part_sec = (try snap_file.Reader.find(m55_snap, .part)).?;
    try testing.expectEqual(board_snap.named_part_tag, part_sec.payload[0]);
    try testing.expectEqualStrings("cortex-m55", part_sec.payload[1..]);

    try expectSnapshotLoads(testing.allocator, &catalog.cortex_m55, m55_snap);
    const others = [_]*const Machine{
        &catalog.cortex_m33,
        &catalog.cortex_m85,
        &catalog.ra8d2,
        &catalog.ra8p1,
        &catalog.ra8e1,
        &catalog.ra4t1,
    };
    for (others) |other| {
        try expectSnapshotWrongPart(testing.allocator, other, m55_snap);
        const other_snap = try snapshotFor(testing.allocator, other);
        defer testing.allocator.free(other_snap);
        try expectSnapshotWrongPart(testing.allocator, &catalog.cortex_m55, other_snap);
    }
}
