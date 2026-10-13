//! Covers src/interfaces/cli/zig/run.zig: the board's side of a Zig-core
//! boundary.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");

const memmap = ra8.chip.core.memmap;
const zig_run = cli_app.zig.run;
const profile = ra8.session.functions.profile;
const profile_report = cli_app.report.profile;
const cpu_boot = ra8.chip.core.cpu.boot;
const symbols = ra8.session.symbols;
const Builder = @import("../../../session/symbol_image.zig").Builder;
const store_board = @import("../store_board.zig");
const Store = store_board.Store;
const Guest = store_board.Guest;
const attach = store_board.attach;
const elf = ra8.board.image.elf;
const Cpu0 = ra8.board.cpu0_store.Cpu0;
const Parts = cli_app.parts.Parts;
const cpu0_image = @embedFile("../../../fixtures/trustzone/cpu1_pingpong_ipc.elf");
const cpu1_image = @embedFile("../../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
const cpu1_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf";
const Rig = @import("../../../session/board/attachments_test.zig").Rig;

test "CLI Zig run reports its attached soak policy" {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    const options: cli_app.cli.Options = .{ .path = "cpu0.elf", .cpu = .zig, .instructions = 1000 };
    try zig_run.main_path.fit(&board, std.testing.allocator, std.testing.io, options);
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    defer parts.deinit();
    const image = try elf.Image.init(cpu0_image);
    _ = try zig_run.main_path.prepare(&cpu0, &board, std.testing.io, image, &parts, options);
    var asked: ra8.session.run.policy.RunPolicy = .{};
    asked.soak.armed = true;
    asked.attach(&board);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    _ = try zig_run.run(&output.writer, std.testing.io, cpu0.own(), &board, &parts.timebase, image, options, image.vectorBase().?, null, parts.tap.waiting(), .{ .policy = &asked });
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "soak: ") != null);
}

fn snapshotRun(second: []const u8, state: zig_run.state_args.Options, with_panel: bool, log: ?[]const u8) !u8 {
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var options: cli_app.cli.Options = .{ .path = "cpu0.elf", .cpu = .zig, .cpu1_path = second, .instructions = 1_000, .state = state };
    options.frames.eink_log = log;
    if (with_panel) {
        options.attaches[0] = try ra8.components.request.parse("eink:64x64@spi:spi1@ssl2");
        options.attach_count = 1;
    }
    try zig_run.main_path.fit(&board, std.testing.allocator, std.testing.io, options);
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    defer parts.deinit();
    const image = try elf.Image.init(cpu0_image);
    _ = try zig_run.main_path.prepare(&cpu0, &board, std.testing.io, image, &parts, options);
    var output = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer output.deinit();
    return zig_run.run(&output.writer, std.testing.io, cpu0.own(), &board, &parts.timebase, image, options, image.vectorBase().?, null, parts.tap.waiting(), .{});
}

test "CLI dual snapshot rejects a different valid CPU1 ELF before restore" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const saved = try std.fs.path.join(std.testing.allocator, &.{ root, "dual.state" });
    defer std.testing.allocator.free(saved);
    const other = try std.fs.path.join(std.testing.allocator, &.{ root, "other.elf" });
    defer std.testing.allocator.free(other);
    const log = try std.fs.path.join(std.testing.allocator, &.{ root, "wrong.jsonl" });
    defer std.testing.allocator.free(log);
    var alternate = try std.testing.allocator.alloc(u8, cpu1_image.len + 1);
    defer std.testing.allocator.free(alternate);
    @memcpy(alternate[0..cpu1_image.len], cpu1_image);
    alternate[cpu1_image.len] = 0x42;
    _ = try elf.Image.init(alternate);
    var out = try tmp.dir.createFile(std.testing.io, "other.elf", .{});
    defer out.close(std.testing.io);
    try out.writeStreamingAll(std.testing.io, alternate);
    try std.testing.expectEqual(@as(u8, 0), try snapshotRun(cpu1_path, .{ .save = saved }, true, log));
    try std.testing.expectError(error.ImageMismatch, snapshotRun(other, .{ .load = saved }, true, log));
}

test "CLI named panel snapshot save and load keep e-ink log available" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const saved = try std.fs.path.join(std.testing.allocator, &.{ root, "panel.state" });
    defer std.testing.allocator.free(saved);
    const log = try std.fs.path.join(std.testing.allocator, &.{ root, "panel.jsonl" });
    defer std.testing.allocator.free(log);
    try std.testing.expectEqual(@as(u8, 0), try snapshotRun(cpu1_path, .{ .save = saved }, true, log));
    try std.testing.expectEqual(@as(u8, 0), try snapshotRun(cpu1_path, .{ .load = saved }, true, log));
    const bytes = try tmp.dir.readFileAlloc(std.testing.io, "panel.state", std.testing.allocator, .limited(1 << 27));
    defer std.testing.allocator.free(bytes);
    try std.testing.expect((try ra8.snapshot.file.Reader.find(bytes, .attachments)) != null);
    const records = try tmp.dir.readFileAlloc(std.testing.io, "panel.jsonl", std.testing.allocator, .limited(1 << 20));
    defer std.testing.allocator.free(records);
}

test "plain Clock restore transfers named panel owner and keeps recorder and failed load stable" {
    const rig = try Rig.create();
    defer rig.destroy();
    const asks = [_]ra8.components.request.Request{.{ .name = "eink", .at = .{ .spi = .{ .channel = 1, .select = 2 } } }};
    rig.board.asks.keep(rig.arena.allocator(), &asks);
    try ra8.board.plug.all(&rig.board);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const save_path = try std.fs.path.join(std.testing.allocator, &.{ root, "clean" });
    defer std.testing.allocator.free(save_path);
    const bad_path = try std.fs.path.join(std.testing.allocator, &.{ root, "bad" });
    defer std.testing.allocator.free(bad_path);
    const after_path = try std.fs.path.join(std.testing.allocator, &.{ root, "after" });
    defer std.testing.allocator.free(after_path);
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = .{ .store = &rig.store }, .board = &rig.board, .timebase = &rig.edge.timebase, .state = .{ .save = save_path } };
    defer clock.deinitSnapshot();
    var recorder = cli_app.eink_log.Run.init(std.testing.allocator, &rig.board);
    defer recorder.deinit();
    recorder.arm();
    var hook = zig_run.zig_snapshot.hook(&clock).?;
    try hook.saveFn.?(hook.context, &rig.cpu, 0);
    const old_panel = rig.board.asks.attached_eink.?;
    clock.state.load = save_path;
    hook = zig_run.zig_snapshot.hook(&clock).?;
    _ = try hook.loadFn.?(hook.context, &rig.cpu);
    const panel = rig.board.asks.attached_eink.?;
    try std.testing.expect(panel != old_panel);
    try std.testing.expectEqual(@as(usize, 1), clock.snapshot_owner.?.plugs.snapshot_owned_count);
    const geometry = panel.planes.geometry;
    const callback = panel.refresh_log_hook.?;
    callback.refreshFn(callback.context, .{ .x = 0, .y = 0, .width = geometry.width, .height = geometry.height, .waveform = 2 });
    try std.testing.expectEqual(@as(usize, 1), recorder.entries.items.len);
    try std.testing.expect(recorder.entries.items[0].full);
    const clean = try tmp.dir.readFileAlloc(std.testing.io, "clean", std.testing.allocator, .limited(1 << 27));
    defer std.testing.allocator.free(clean);
    const section = (try ra8.snapshot.file.Reader.find(clean, .attachments)).?;
    const offset = @intFromPtr(section.payload.ptr) - @intFromPtr(clean.ptr);
    var bad = try std.testing.allocator.dupe(u8, clean);
    defer std.testing.allocator.free(bad);
    bad[offset] = 0xff;
    var out = try tmp.dir.createFile(std.testing.io, "bad", .{});
    defer out.close(std.testing.io);
    try out.writeStreamingAll(std.testing.io, bad);
    clock.state.load = bad_path;
    try std.testing.expectError(error.BadValue, hook.loadFn.?(hook.context, &rig.cpu));
    try std.testing.expect(rig.board.asks.attached_eink.? == panel);
    try std.testing.expectEqual(@as(usize, 1), recorder.entries.items.len);
    clock.state.save = after_path;
    try hook.saveFn.?(hook.context, &rig.cpu, 0);
    const after = try tmp.dir.readFileAlloc(std.testing.io, "after", std.testing.allocator, .limited(1 << 27));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualSlices(u8, clean, after);
}

test "a boundary is the chunk until SysTick is armed, then its period" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
    try core.writeWord(memmap.syst.rvr, 999);
    try core.writeWord(memmap.syst.csr, 0x7);
    try std.testing.expectEqual(@as(u32, 1000), clock.width());
    try core.writeWord(memmap.syst.rvr, 99_999);
    try std.testing.expectEqual(@as(u32, 5000), clock.width());
}

test "closing a boundary charges the clocks and wraps SysTick into ICSR" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase };
    try clock.close(7);
    try std.testing.expectEqual(@as(u64, 7), timebase.elapsed);
    try core.writeWord(memmap.syst.rvr, 9);
    try core.writeWord(memmap.syst.cvr, 0);
    try core.writeWord(memmap.syst.csr, 0x7);
    try clock.close(10);
    try std.testing.expectEqual(@as(u64, 17), timebase.elapsed);
    try std.testing.expect(timebase.ticks > 0);
}

test "closing a boundary charges cycles at the image core clock" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    board.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.moco);
    board.tree.selects = 1;
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 50_000 };
    var timed: ra8.chip.core.deadline.Deadline = .{ .periods = 1000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .timed = &timed };
    try core.writeWord(memmap.syst.rvr, 7999);
    try core.writeWord(memmap.syst.csr, 0x7);
    try std.testing.expectEqual(@as(u32, 50_000), clock.width());

    board.time.base.setRate(ra8.chip.periph.clocks.timebase.default_hz);
    clock.resume_boundary = true;
    clock.boundary_hz = null;
    try std.testing.expectEqual(@as(u32, 8000), clock.width());
    try std.testing.expectEqual(ra8.chip.periph.clocks.timebase.default_hz, board.time.base.hz);
    clock.resume_boundary = false;
    clock.boundary_hz = null;
    _ = clock.width();
    try std.testing.expectEqual(@as(u64, 8_000_000), board.time.base.hz);
    const gptp = ra8.chip.periph.gptp;
    const gptp_timer = ra8.chip.periph.gptp.timer;
    const unit = gptp.win_base + gptp.unitOffset(0);
    board.ptp.write(unit + gptp.unit_off.ptptivc, 4, 4 << gptp_timer.scale.subns_shift);
    board.ptp.write(gptp.win_base + gptp.off.ptptmec, 4, 1);
    try clock.close(1000);
    try std.testing.expectEqual(@as(u64, 8), timebase.elapsed);
    try std.testing.expectEqual(@as(u64, 8), board.time.base.retired);
    try std.testing.expectEqual(@as(u32, 1000), board.ptp.read(unit + gptp.unit_off.ptpgptptml, 4));
    try clock.close(4000);
    try std.testing.expectEqual(@as(u64, 40), timebase.elapsed);
    try std.testing.expectEqual(@as(u64, 40), board.time.base.retired);
    try std.testing.expect(!clock.done());
    try clock.close(999_995_000);
    try std.testing.expectEqual(@as(u64, 8_000_000), timebase.elapsed);
    try std.testing.expectEqual(@as(u64, 1000), timebase.ticks);
    try std.testing.expect(clock.done());
}

test "--run-for ends after its duration of a reset-clock image's own time (RA8EMU-762)" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    board.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.moco);
    board.tree.selects = 1;
    const options = try cli_app.cli.parse(&[_][]const u8{ "emu", "a.elf", "--run-for", "1s" });
    var timed = zig_run.stop_sym.deadline(options.ms) orelse return error.TestExpectedDeadline;
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 1_000_000 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .timed = &timed };
    try core.writeWord(memmap.syst.rvr, 7999);
    try core.writeWord(memmap.syst.csr, 0x7);
    var closes: usize = 0;
    while (!clock.done()) : (closes += 1) {
        if (closes > 4000) return error.TestDeadlineNeverMet;
        try clock.close(clock.width());
    }
    try std.testing.expectEqual(@as(u64, 8_000_000), board.time.base.hz);
    try std.testing.expectEqual(@as(u64, 1000), timebase.ticks);
    const now = board.time.base.now();
    try std.testing.expect(now >= std.time.ns_per_s and now < std.time.ns_per_s + std.time.ns_per_ms);
}

test "a SysTick rearm discards the current boundary rate" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    board.tree.cksel = @backingInt(ra8.chip.periph.sysclk.Source.moco);
    board.tree.selects = 1;
    var timebase: ra8.chip.periph.clocks.Clocks = .{};
    var timed: ra8.chip.core.deadline.Deadline = .{ .periods = 1 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .timed = &timed };
    try core.writeWord(memmap.syst.rvr, 7999);
    try core.writeWord(memmap.syst.csr, 0x7);
    _ = clock.width();
    try std.testing.expectEqual(@as(?u64, 8_000_000), clock.boundary_hz);

    const boundary = clock.boundary();
    boundary.abortFn.?(boundary.context);
    try std.testing.expectEqual(@as(?u64, null), clock.boundary_hz);
    board.time.base.setRate(ra8.chip.periph.clocks.timebase.default_hz);
    _ = clock.width();
    try std.testing.expectEqual(@as(u64, 8_000_000), board.time.base.hz);
}

fn profileInstruction(context: *anyopaque, address: u32) void {
    const table: *profile.Table = @ptrCast(@alignCast(context));
    table.instruction(address);
}

test "a Zig core run profiles retired function instructions and writes folded output" {
    const base = memmap.sram_base;
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    try core.writeWord(base, memmap.sram_end);
    try core.writeWord(base + 4, base + 9);
    try core.writeWord(base + 8, 0xBF00_BF00);
    try core.writeWord(base + 12, 0xBF00_BF00);

    var image_bytes: [512]u8 = undefined;
    const encoded = Builder.build(&image_bytes, &.{"profiled_function"}, &.{base + 9});
    const symbol: *align(1) symbols.Symbol = std.mem.bytesAsValue(symbols.Symbol, encoded[Builder.sym_off..][0..@sizeOf(symbols.Symbol)]);
    symbol.st_info = symbols.symbol_type.func;
    symbol.st_size = 8;
    const image = try ra8.board.image.elf.Image.init(encoded);
    var table: profile.Table = .{ .image = image };
    table.prepare();

    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var ran: u64 = 0;
    var output: [512]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&output);
    const listener: ra8.chip.core.cpu.cpu.RetireListener = .{ .context = &table, .instructionFn = profileInstruction };
    const status = try cpu_boot.start(&stream, .zig, core, &board.bus, base, 3, &ran, .{ .retire_listener = listener });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 3), ran);
    var rows: [profile.limits.functions]profile.Site = undefined;
    const ranked = table.ranked(&rows);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqual(base + 8, ranked[0].address);
    try std.testing.expectEqual(@as(u64, 3), ranked[0].instructions);
    try std.testing.expectEqual(@as(u64, 3), ranked[0].cycles);

    const summary_path = ".ra8-profile-zig-run-test.out";
    const folded_path = ".ra8-profile-zig-run-test.folded";
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, folded_path) catch {};
    var summary = try std.Io.Dir.cwd().createFile(std.testing.io, summary_path, .{ .truncate = true });
    defer summary.close(std.testing.io);
    var buffer: [4096]u8 = undefined;
    var writer = summary.writer(std.testing.io, &buffer);
    try profile_report.write(&writer.interface, std.testing.io, image, table, folded_path, null);
    try writer.interface.flush();
    const folded = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, folded_path, std.testing.allocator, .limited(128));
    defer std.testing.allocator.free(folded);
    try std.testing.expectEqualStrings("profiled_function 3\n", folded);
}

test {
    _ = @import("../../../session/stack/profile_test.zig");
    _ = @import("main_test.zig");
    _ = @import("../idle_skip_equiv_test.zig");
    _ = @import("../sleep_wake_test.zig");
    _ = @import("../soak_done_test.zig");
    _ = @import("../soak_canary_test.zig");
    _ = @import("../threadx_stkof_test.zig");
    _ = @import("../tz_pair_test.zig");
}

test "a boundary is done once the --stop-sym counter reaches its floor (RA8EMU-603)" {
    var store = try Store.init(null);
    defer store.deinit();
    const core: Guest = .{ .store = &store };
    var board = ra8.board.board.Board.init(std.testing.allocator);
    defer board.deinit();
    try attach(&board, core);
    var timebase: ra8.chip.periph.clocks.Clocks = .{ .per_chunk = 5000 };
    var watch: ra8.chip.core.stop.Stop = .{ .address = 0x2200_0100, .reaches = 3 };
    var clock: zig_run.Clock = .{ .io = std.testing.io, .memory = core, .board = &board, .timebase = &timebase, .stop = &watch };
    try core.writeWord(0x2200_0100, 2);
    try std.testing.expect(!clock.done());
    try core.writeWord(0x2200_0100, 4);
    try std.testing.expect(clock.done());
    try std.testing.expect(watch.reached);
    const edge = clock.boundary();
    try std.testing.expect(edge.doneFn.?(edge.context));
}
