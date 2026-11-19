//! Generic machine integration tests covering CLI flags, reports, `--until`,
//! single-core session bounds, DAP, GDB, and cross-part snapshots.
const std = @import("std");
const cli_app = @import("cli_app");
const ra8 = @import("ra8");

const Adapter = ra8.dap.adapter.Adapter;
const Board = ra8.board.board.Board;
const board_snap = ra8.board.snapshot.board;
const catalog = ra8.chip.core.machine.catalog;
const cli = cli_app.cli;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const elf = ra8.board.image.elf;
const gdb_dispatch = ra8.gdb.rsp.dispatch;
const harness_mod = ra8.session.harness;
const json_run = cli_app.report.json.run;
const part_report = cli_app.report.part;
const Parts = cli_app.parts.Parts;
const snap_file = ra8.snapshot.file;
const Store = ra8.chip.core.cpu.memory.store.Store;
const symbols = ra8.session.symbols;
const wiring = ra8.board.wiring;

const m33_elf = @embedFile("../fixtures/generic_machines/cortex_m33.elf");
const m85_elf = @embedFile("../fixtures/generic_machines/cortex_m85.elf");

fn openHarness(
    bytes: []const u8,
    machine: *const ra8.chip.core.machine.Machine,
    history_frames: u32,
) !harness_mod.Harness {
    return harness_mod.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = bytes,
        .machine = machine,
        .history_frames = history_frames,
    });
}

fn wallNow(context: *anyopaque) u64 {
    const clock: *u64 = @ptrCast(@alignCast(context));
    return clock.*;
}

fn dapSend(adapter: *Adapter, request: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try adapter.request(request, &out.writer);
    return std.testing.allocator.dupe(u8, out.written());
}

fn dapPump(adapter: *Adapter) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var pumps: usize = 0;
    while (adapter.pending != null) : (pumps += 1) {
        if (pumps >= 500) return error.PumpLimitExceeded;
        try adapter.pump(&out.writer);
    }
    return std.testing.allocator.dupe(u8, out.written());
}

fn expectDapHas(adapter: *Adapter, request: []const u8, needle: []const u8) ![]u8 {
    const got = try dapSend(adapter, request);
    errdefer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, needle) != null);
    return got;
}

fn dapCheck(adapter: *Adapter, request: []const u8, needle: []const u8) !void {
    const got = try expectDapHas(adapter, request, needle);
    std.testing.allocator.free(got);
}

fn parseNumberAfter(text: []const u8, key: []const u8) !u32 {
    const start = (std.mem.indexOf(u8, text, key) orelse return error.MissingKey) + key.len;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    return std.fmt.parseInt(u32, text[start..end], 10);
}

fn saveBoardSnapshot(board: *const Board) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try snap_file.writeHeader(&out.writer);
    try board_snap.save(board, &out.writer);
    return std.testing.allocator.dupe(u8, out.written());
}

fn dapStartSingleThread(adapter: *Adapter, expected_name: []const u8) !void {
    const init_req = "{\"seq\":1,\"type\":\"request\",\"command\":\"initialize\",\"arguments\":{}}";
    try dapCheck(adapter, init_req, "\"supportsStepBack\"");
    try dapCheck(adapter, "{\"seq\":2,\"type\":\"request\",\"command\":\"attach\",\"arguments\":{}}", "\"success\"");
    try dapCheck(adapter, "{\"seq\":3,\"type\":\"request\",\"command\":\"configurationDone\"}", "\"entry\"");
    const threads_req = "{\"seq\":4,\"type\":\"request\",\"command\":\"threads\"}";
    const threads = try expectDapHas(adapter, threads_req, expected_name);
    defer std.testing.allocator.free(threads);
    try std.testing.expect(std.mem.indexOf(u8, threads, "\"id\":2") == null);
    const bad = "{\"seq\":5,\"type\":\"request\",\"command\":\"stepIn\"," ++
        "\"arguments\":{\"threadId\":2,\"granularity\":\"instruction\"}}";
    try dapCheck(adapter, bad, "UnknownThread");
}

fn dapInspectStopped(adapter: *Adapter) !void {
    const stack = try expectDapHas(
        adapter,
        "{\"seq\":8,\"type\":\"request\",\"command\":\"stackTrace\",\"arguments\":{\"threadId\":1}}",
        "\"stackFrames\"",
    );
    defer std.testing.allocator.free(stack);
    const frame_id = try parseNumberAfter(stack, "\"id\":");
    var req_buf: [128]u8 = undefined;
    const scopes_req = try std.fmt.bufPrint(
        &req_buf,
        "{{\"seq\":9,\"type\":\"request\",\"command\":\"scopes\",\"arguments\":{{\"frameId\":{d}}}}}",
        .{frame_id},
    );
    const scopes = try expectDapHas(adapter, scopes_req, "\"Registers\"");
    defer std.testing.allocator.free(scopes);
    const vars_ref = try parseNumberAfter(scopes, "\"variablesReference\":");
    const vars_req = try std.fmt.bufPrint(
        &req_buf,
        "{{\"seq\":10,\"type\":\"request\",\"command\":\"variables\",\"arguments\":{{\"variablesReference\":{d}}}}}",
        .{vars_ref},
    );
    try dapCheck(adapter, vars_req, "\"name\":\"pc\"");
}

fn checkSingleCoreDap(
    bytes: []const u8,
    machine: *const ra8.chip.core.machine.Machine,
    expected_name: []const u8,
) !void {
    var h = try openHarness(bytes, machine, 8);
    defer h.deinit();
    var adapter = Adapter{
        .allocator = std.testing.allocator,
        .target = .{ .session = h.session(), .images = .{ h.image(), null } },
    };
    defer adapter.deinit();
    try dapStartSingleThread(&adapter, expected_name);

    const tick = symbols.addressOf(h.image(), "SysTick_Handler") orelse return error.MissingSymbol;
    var bp_buf: [160]u8 = undefined;
    const bp_req = try std.fmt.bufPrint(
        &bp_buf,
        "{{\"seq\":6,\"type\":\"request\",\"command\":\"setInstructionBreakpoints\"," ++
            "\"arguments\":{{\"breakpoints\":[{{\"instructionReference\":\"0x{X:0>8}\"}}]}}}}",
        .{tick & ~@as(u32, 1)},
    );
    try dapCheck(&adapter, bp_req, "\"verified\":true");
    try dapCheck(
        &adapter,
        "{\"seq\":7,\"type\":\"request\",\"command\":\"continue\",\"arguments\":{\"threadId\":1}}",
        "\"allThreadsContinued\":true",
    );
    const pumped = try dapPump(&adapter);
    defer std.testing.allocator.free(pumped);
    try std.testing.expect(std.mem.indexOf(u8, pumped, "\"instruction breakpoint\"") != null);

    try dapInspectStopped(&adapter);
    try dapCheck(
        &adapter,
        "{\"seq\":11,\"type\":\"request\",\"command\":\"stepIn\"," ++
            "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}",
        "\"success\":true",
    );
    const stepped = try dapPump(&adapter);
    defer std.testing.allocator.free(stepped);
    try std.testing.expect(std.mem.indexOf(u8, stepped, "\"reason\":\"step\"") != null);
    try dapCheck(
        &adapter,
        "{\"seq\":12,\"type\":\"request\",\"command\":\"stepBack\"," ++
            "\"arguments\":{\"threadId\":1,\"granularity\":\"instruction\"}}",
        "\"reason\":\"step\"",
    );
    try dapCheck(&adapter, "{\"seq\":13,\"type\":\"request\",\"command\":\"restart\"}", "\"reason\":\"entry\"");
}

fn checkSingleCoreGdb(
    bytes: []const u8,
    machine: *const ra8.chip.core.machine.Machine,
    expected_arch: []const u8,
) !void {
    var h = try openHarness(bytes, machine, 1);
    defer h.deinit();

    var now: u64 = 0;
    var target = gdb_dispatch.zig_run.Target{
        .session = h.session(),
        .wall = .{ .context = &now, .nowFn = wallNow },
    };
    const dispatch = gdb_dispatch.Dispatch{ .zig = &target };
    var out: [4096]u8 = undefined;

    const xml = try dispatch.answer("qXfer:features:read:target.xml:0,fff", &out);
    try std.testing.expect(std.mem.indexOf(u8, xml, expected_arch) != null);
    try std.testing.expectEqualStrings("m1", try dispatch.answer("qfThreadInfo", &out));
    try std.testing.expectEqualStrings("l", try dispatch.answer("qsThreadInfo", &out));
    try std.testing.expectEqualStrings("QC1", try dispatch.answer("qC", &out));
    try std.testing.expectEqualStrings("OK", try dispatch.answer("T1", &out));
    try std.testing.expectEqualStrings("E00", try dispatch.answer("T2", &out));
    try std.testing.expectEqualStrings("E00", try dispatch.answer("Hg2", &out));
    try std.testing.expectEqualStrings("E00", try dispatch.answer("vCont;s:2", &out));

    const park = (symbols.addressOf(h.image(), "generic_park") orelse return error.MissingSymbol) & ~@as(u32, 1);
    var pkt_buf: [64]u8 = undefined;
    const set_bp = try std.fmt.bufPrint(&pkt_buf, "Z0,{x},2", .{park});
    try std.testing.expectEqualStrings("OK", try dispatch.answer(set_bp, &out));
    const stopped = try dispatch.answer("c", &out);
    try std.testing.expect(std.mem.startsWith(u8, stopped, "T05"));
    try std.testing.expectEqual(@as(usize, 17 * 8), (try dispatch.answer("g", &out)).len);
    try std.testing.expect(std.mem.startsWith(u8, try dispatch.answer("s", &out), "T05"));
    const clr_bp = try std.fmt.bufPrint(&pkt_buf, "z0,{x},2", .{park});
    try std.testing.expectEqualStrings("OK", try dispatch.answer(clr_bp, &out));
}

test "CLI accepts cortex-m33 and cortex-m85 parts and refuses --cpu1 and unknown parts" {
    const m33 = try cli.parse(&.{ "emu", "fw.elf", "--part", "cortex-m33" });
    try std.testing.expectEqual(&catalog.cortex_m33, m33.machine.?);
    try std.testing.expect(m33.part_set);

    const m85 = try cli.parse(&.{ "emu", "fw.elf", "--device", "cortex-m85" });
    try std.testing.expectEqual(&catalog.cortex_m85, m85.machine.?);
    try std.testing.expect(m85.part_set);

    try std.testing.expectError(
        error.AbsentCore,
        cli.parse(&.{ "emu", "fw.elf", "--part", "cortex-m33", "--cpu1", "cpu1.elf" }),
    );
    try std.testing.expectError(
        error.AbsentCore,
        cli.parse(&.{ "emu", "fw.elf", "--part", "cortex-m85", "--cpu1", "cpu1.elf" }),
    );
    try std.testing.expectError(error.UnknownPart, cli.parse(&.{ "emu", "fw.elf", "--part", "no-such-machine" }));
}

test "text and JSON machine reports omit CPU1 fields and show custom geometry" {
    try std.testing.expect(part_report.shownMachine(&catalog.cortex_m33));
    try std.testing.expect(part_report.shownMachine(&catalog.cortex_m85));

    var buf: [256]u8 = undefined;
    const m33_line = try part_report.lineMachine(&buf, &catalog.cortex_m33);
    try std.testing.expectEqualStrings(
        "PART: Cortex-M33 FLASH 256 KB @0x00000000, SRAM 64 KB @0x20000000, " ++
            "CPU0 Cortex-M33 (Armv8-M Architecture Reference Manual)\n",
        m33_line,
    );
    const m85_line = try part_report.lineMachine(&buf, &catalog.cortex_m85);
    try std.testing.expectEqualStrings(
        "PART: Cortex-M85 FLASH 256 KB @0x00000000, SRAM 64 KB @0x20000000, " ++
            "CPU0 Cortex-M85 (Armv8-M Architecture Reference Manual)\n",
        m85_line,
    );

    var h = try openHarness(m33_elf, &catalog.cortex_m33, 0);
    defer h.deinit();

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try json_run.document(&out.writer, h.board(), .{ .engine = "zig", .elapsed = 10 });
    const doc = out.written();
    const want_part = "\"part\":{\"name\":\"Cortex-M33\",\"mram_base\":0,\"mram_bytes\":262144," ++
        "\"sram_base\":536870912,\"sram_bytes\":65536,\"cpu0_tcm_bytes\":0,\"cpu0_cache_bytes\":0";
    try std.testing.expect(std.mem.indexOf(u8, doc, want_part) != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"cpu1_tcm_bytes\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"cores\":{\"ipc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "\"cpu1\"") == null);
}

test "CLI runner stops early on --until ITM line for generic machines" {
    const io = std.testing.io;
    const options = try cli.parse(&.{ "emu", "cortex_m33.elf", "--part", "cortex-m33", "--until", "GENERIC END" });
    const image = try elf.Image.init(m33_elf);

    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    try cli_app.zig.run.main_path.fit(board, std.testing.allocator, io, options);

    const cpu0 = try std.testing.allocator.create(Cpu0);
    defer std.testing.allocator.destroy(cpu0);
    cpu0.* = .{};
    defer cpu0.close();

    const parts = try std.testing.allocator.create(Parts);
    defer std.testing.allocator.destroy(parts);
    parts.* = .{};
    defer parts.deinit();
    _ = try cli_app.zig.run.main_path.prepare(cpu0, board, io, image, parts, options);
    const vtor = try cli_app.zig.run.main_path.vectorBaseFor(image, board.desc().memory);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const exit_code = try cli_app.zig.run.run(
        &out.writer,
        io,
        cpu0.own(),
        board,
        &parts.timebase,
        image,
        options,
        vtor,
        null,
        parts.tap.waiting(),
        .{},
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expect(parts.tap.waiting().?.reached);
    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "stopped clean on the console line \"GENERIC END\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "PART: Cortex-M33 FLASH 256 KB") != null);
}

test "single-core harness refuses CPU1 access and vpr on cortex-m33" {
    {
        var m33 = try openHarness(m33_elf, &catalog.cortex_m33, 0);
        defer m33.deinit();
        try std.testing.expect(!m33.session().hasCore(.cpu1));
        try std.testing.expectEqual(@as(?ra8.chip.core.machine.Core, null), m33.session().coreInfo(.cpu1));
        try std.testing.expectError(error.CoreNotAttached, m33.session().machine(.cpu1));
        try std.testing.expectError(error.CoreNotAttached, m33.session().view(.cpu1));
        try std.testing.expectError(error.UnsupportedRegister, m33.session().register(.cpu0, .vpr));
    }
    {
        var m85 = try openHarness(m85_elf, &catalog.cortex_m85, 0);
        defer m85.deinit();
        try std.testing.expect(!m85.session().hasCore(.cpu1));
        _ = try m85.session().register(.cpu0, .vpr);
    }
}

test "single-thread DAP operates on cortex-m33 and cortex-m85 and refuses thread 2" {
    try checkSingleCoreDap(m33_elf, &catalog.cortex_m33, "CPU0 (Cortex-M33)");
    try checkSingleCoreDap(m85_elf, &catalog.cortex_m85, "CPU0 (Cortex-M85)");
}

test "single-thread GDB reports distinct architecture XML and single thread on generic machines" {
    try checkSingleCoreGdb(m33_elf, &catalog.cortex_m33, "<architecture>armv8-m.main</architecture>");
    try checkSingleCoreGdb(m85_elf, &catalog.cortex_m85, "<architecture>armv8.1-m.main</architecture>");
}

fn checkSnapBoard(machine: *const ra8.chip.core.machine.Machine, expect_wrong: ?[]const u8) !?[]u8 {
    const store = try std.testing.allocator.create(Store);
    defer std.testing.allocator.destroy(store);
    store.* = try Store.init(null);
    defer store.deinit();
    const board = try std.testing.allocator.create(Board);
    defer std.testing.allocator.destroy(board);
    board.* = Board.init(std.testing.allocator);
    defer board.deinit();
    board.machine = machine;
    board.part = machine.part;
    try wiring.attachBlocks(board, .{ .store = store });
    if (expect_wrong) |bytes| {
        try std.testing.expectError(error.WrongPart, board_snap.load(board, bytes));
        return null;
    }
    return try saveBoardSnapshot(board);
}

fn checkSnapHarness(
    elf_bytes: []const u8,
    machine: *const ra8.chip.core.machine.Machine,
    load_bytes: ?[]const u8,
    want_err: ?anyerror,
) !?[]u8 {
    var h = try openHarness(elf_bytes, machine, 0);
    defer h.deinit();
    const bytes = load_bytes orelse return try saveBoardSnapshot(h.board());
    if (want_err) |err| {
        try std.testing.expectError(err, board_snap.load(h.board(), bytes));
    } else try board_snap.load(h.board(), bytes);
    return null;
}

test "snapshots refuse WrongPart across cortex-m33, cortex-m85, ra8d2, and ra8p1" {
    const m33_bytes = (try checkSnapHarness(m33_elf, &catalog.cortex_m33, null, null)).?;
    defer std.testing.allocator.free(m33_bytes);
    const part_sec = (try snap_file.Reader.find(m33_bytes, .part)).?;
    try std.testing.expectEqual(board_snap.named_part_tag, part_sec.payload[0]);
    try std.testing.expectEqualStrings("cortex-m33", part_sec.payload[1..]);

    const m85_bytes = (try checkSnapHarness(m85_elf, &catalog.cortex_m85, null, null)).?;
    defer std.testing.allocator.free(m85_bytes);
    const d2_bytes = (try checkSnapBoard(&catalog.ra8d2, null)).?;
    defer std.testing.allocator.free(d2_bytes);

    _ = try checkSnapHarness(m33_elf, &catalog.cortex_m33, m33_bytes, null);
    _ = try checkSnapHarness(m85_elf, &catalog.cortex_m85, m33_bytes, error.WrongPart);
    _ = try checkSnapBoard(&catalog.ra8d2, m33_bytes);
    _ = try checkSnapBoard(&catalog.ra8p1, m33_bytes);
    _ = try checkSnapHarness(m33_elf, &catalog.cortex_m33, m85_bytes, error.WrongPart);
    _ = try checkSnapHarness(m33_elf, &catalog.cortex_m33, d2_bytes, error.WrongPart);
}
