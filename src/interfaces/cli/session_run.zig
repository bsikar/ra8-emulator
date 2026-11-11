//! Plain CLI `--camera-source` and `--history` runs over Session history
//! (`RA8EMU-1233`, F08): routes `ra8_emulator <firmware.elf>` through
//! `served_setup.Served` so camera frames, C6 traffic, loopback USB/IP and
//! console input are recorded on the single Session history architecture,
//! and explicitly refuses raw-board-only flag combinations that cannot be
//! recorded.
const std = @import("std");
const cli = @import("cli.zig");
const report = @import("report.zig");
const report_dumps = @import("report/dumps.zig");
const json_regs = @import("report/json/regs.zig");
const frame_out = @import("frame_out.zig");
const zig_main = @import("zig/main.zig");
const served_setup = @import("ra8_rpc").served_setup;
const served_camera = @import("ra8_rpc").served_camera;
const session_api = @import("ra8_session").api;
const recorded_camera = @import("ra8_session").board.recorded_camera;
const mem_dump = @import("ra8_session").mem_dump;
const break_sym = @import("ra8_session").zig.break_sym;
const elf = @import("ra8_board").image.elf;
const usbip_run = @import("ra8_usbip").exported.run;

/// Returns a refusal message when `options` mixes incompatible raw-board
/// flags or invalid Session-history flags, or null when valid.
pub fn validate(options: cli.Options) ?[]const u8 {
    if (options.history.kept and options.history.root == null) {
        return "--kept requires --history DIR";
    }
    if (options.history.budget != null and options.history.root == null) {
        return "--history-budget requires --history DIR";
    }
    if (options.history.ram_budget != null and options.history.root != null) {
        return "--ram-budget requires RAM-only history (--history off or default)";
    }
    if (options.history.checkpoint_every) |every| {
        if (every == 0) return "--checkpoint-every must be at least 1";
    }
    if (options.part_set and options.part != .ra8p1) {
        return "Session history models ra8p1 only; omit --part ra8d2 or pass --part ra8p1";
    }
    if (options.state.save != null or options.state.load != null or options.state.at != null) {
        return "--save-state/--load-state/--snapshot-at/--restore cannot combine with Session history; use --history DIR";
    }
    if (options.net_tape != null) {
        return "--net-record/--net-replay cannot combine with Session history; Session records C6 traffic directly";
    }
    if (options.sd_path != null or options.sd_new != null or options.sd_size_mb != null or options.trace_sd or options.dump_sd != null) {
        return "SPI --sd flags are not recorded by Session history; use --sd-image or --sd-dir";
    }
    if (options.sdhi.writable) {
        return "--sd-writable cannot combine with Session history; startup SDHI media is immutable";
    }
    if (options.ns_path != null) return "--ns cannot combine with Session history";
    if (options.usb_disk != null or options.usb_loop) {
        return "--usb-disk/--usb-loop cannot combine with Session history; use --usbip PORT";
    }
    return validateRawOnly(options);
}

fn validateRawOnly(options: cli.Options) ?[]const u8 {
    if (options.faults != null or options.attach_count != 0 or options.detach_c6 or
        options.click or options.battery.charging or options.battery.soc_pct != 72)
    {
        return "raw board hardware flags (--attach/--fault/--faults/--detach/--click/--battery) cannot combine with plain Session history CLI";
    }
    if (options.touch_in != null or options.input_script != null or options.touch_count != 0) {
        return "raw board touch flags (--touch/--input-script) cannot combine with plain Session history CLI";
    }
    if (options.cms != null or options.sfs != null or options.rtc_start != null or
        options.panel_vsync != null or !options.bus_errors or !options.blocks or
        !options.idle_skip or options.chunk_instructions != null)
    {
        return "raw board core/clock flags cannot combine with plain Session history CLI";
    }
    if (options.stop_symbol != null or options.watch_place != null or options.stop_on_undefined or
        options.count_pc_len != 0 or options.taken_in_place != null or options.trace_rtos or
        options.cpu_load or options.ctl_cpu_load or options.profile or options.report_json)
    {
        return "raw board trace/stop flags cannot combine with plain Session history CLI";
    }
    if (options.frames.frames_out != null or options.frames.eink_log != null or
        options.frames.gif_out != null or options.frames.frame_on_settle != null or
        options.frames.video_out != null or options.audio.path != null)
    {
        return "raw board media export flags (--frames-out/--gif-out/--video-out/--audio-out) cannot combine with plain Session history CLI";
    }
    if (options.console_reply.armed()) return "--console-reply cannot combine with plain Session history CLI";
    if (options.speed != null or options.run_for) return "--speed/--realtime/--run-for cannot combine with plain Session history CLI";
    return null;
}

/// Captured guest and host observables at the end of a Session run or replay.
pub const Outcome = struct {
    state_bytes: []u8,
    console_line: []u8,
    console_lines: u32,
    ceu_frames: u32,
    replayed_frames: u64,
    panel_pixels: []u32,
    panel_width: u32,
    panel_height: u32,
    host_sink_lines: usize,
    position: session_api.Position,
    ended: session_api.Ended,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        allocator.free(self.state_bytes);
        allocator.free(self.console_line);
        allocator.free(self.panel_pixels);
    }
};

/// Host console line counter and `--console` / `--until` sink.
pub const ConsoleSink = struct {
    tap: cli.console_output.Tap = .{},
    host_lines: usize = 0,

    pub fn bind(self: *ConsoleSink, setup: *served_setup.Served, io: std.Io, echo: bool, until_text: ?[]const u8) void {
        self.* = .{
            .tap = .{
                .echo = if (echo) io else null,
                .wait = if (until_text) |needle| .{ .needle = needle } else null,
            },
            .host_lines = 0,
        };
        setup.owner.board().serial.line.setSink(.{ .context = self, .writeFn = onLine });
    }

    fn onLine(context: ?*anyopaque, text: []const u8) anyerror!void {
        const self: *ConsoleSink = @ptrCast(@alignCast(context.?));
        self.host_lines += 1;
        try cli.console_output.tapLine(&self.tap, text);
    }
};

/// Open a `Served` session for `options`, install `--camera-source` and
/// `--usbip` on its recorded ports, and validate the ELF's vector table.
pub fn openSession(
    setup: *served_setup.Served,
    bridges: *std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    io: std.Io,
    elf_bytes: []const u8,
    options: cli.Options,
) !u32 {
    const image = try elf.Image.init(elf_bytes);
    const vector_base = try zig_main.vectorBase(image);
    const history_opts: served_setup.HistoryOpts = .{
        .root = options.history.root,
        .checkpoint_every = options.history.checkpoint_every orelse 64,
        .budget = options.history.budget,
        .ram_budget = options.history.ram_budget,
        .kept = options.history.kept,
        .elf_bytes = elf_bytes,
    };
    const second: ?served_setup.SecondImage = if (options.cpu1_path) |p| .{ .path = p } else null;
    try setup.openInputs(allocator, io, options.path, options.board_profile, history_opts, second, .{ .card = options.sdhi });
    errdefer setup.deinit();
    if (options.history.camera_set or options.camera.kind != .gradient) {
        try served_camera.set(setup, options.camera);
    }
    if (options.usbip) |port| {
        try usbip_run.install(&setup.owner.board().usb, bridges.allocator(), io, port);
        try setup.attachUsbip();
    }
    return vector_base;
}

/// Drive `setup` forward according to `options` (`--instructions`, `--ms`,
/// `--until`, `--break-sym` / `--break-at`) and flush its history.
pub fn driveSession(setup: *served_setup.Served, sink: *ConsoleSink, options: cli.Options) !session_api.Ended {
    const session = setup.owner.session();
    const bp = break_sym.resolve(setup.owner.image(), options.break_place, options.break_arrival);
    const bp_id = if (bp) |point| try session.setBreakpoint(.cpu0, .{ .address = @intCast(point.watchedAddress()) }) else null;
    defer if (bp_id) |id| session.clearBreakpoint(.cpu0, id) catch {};

    const total_budget: u64 = @intCast(options.budgetFor(false));
    const target_ns: ?u64 = if (options.ms) |ms| std.math.mul(u64, ms, std.time.ns_per_ms) catch std.math.maxInt(u64) else null;
    var remaining = total_budget;
    var hits: u32 = 0;
    var last: session_api.Ended = .count;

    while (remaining > 0) {
        if (sink.tap.waiting()) |wait| if (wait.met()) break;
        if (target_ns) |limit_ns| if ((try session.now()) >= limit_ns) break;
        const step_budget = if (sink.tap.waiting() != null or target_ns != null) @min(remaining, 50_000) else remaining;
        try session.setRunBudget(.cpu0, step_budget);
        const start_inst = setup.owner.primaryCpu().retired;
        const cmd: session_api.Run = if (!session.live.started) .run else .cont;
        last = try session.run(.cpu0, cmd);
        const retired = setup.owner.primaryCpu().retired -| start_inst;
        remaining -|= if (retired == 0) 1 else retired;
        if (session.persistent_recorder) |rec| try rec.maybeCommit(rec.now());
        if (last == .stop and last.stop == .breakpoint) {
            hits += 1;
            if (hits >= options.break_arrival) break;
            _ = try session.step(.cpu0);
            remaining -|= 1;
            continue;
        }
        if (last != .count) break;
    }
    try setup.flushHistory();
    return last;
}

/// Capture guest and host state from `setup` after a run or replay.
pub fn captureOutcome(allocator: std.mem.Allocator, setup: *served_setup.Served, sink: *const ConsoleSink, ended: session_api.Ended) !Outcome {
    var state_writer: std.Io.Writer.Allocating = .init(allocator);
    defer state_writer.deinit();
    try setup.owner.state.files.writeTo(&state_writer.writer);
    const state_bytes = try allocator.dupe(u8, state_writer.written());
    errdefer allocator.free(state_bytes);

    const board = setup.owner.board();
    const console_line = try allocator.dupe(u8, board.serial.line.slice());
    errdefer allocator.free(console_line);

    const w = board.display.panelWidth();
    const h = board.display.panelHeight();
    const pixels = try allocator.alloc(u32, @as(usize, w) * h);
    errdefer allocator.free(pixels);
    @memset(pixels, 0);
    if (w != 0 and h != 0) {
        board.display.output.capture = .{ .pixels = pixels, .width = w, .height = h };
        defer board.display.output.capture = null;
        _ = board.display.scanOut();
    }
    const cam_replayed = if (recorded_camera.from(board.capture.source)) |rc| rc.replayed else 0;
    return .{
        .state_bytes = state_bytes,
        .console_line = console_line,
        .console_lines = board.serial.line.lines,
        .ceu_frames = board.capture.frames,
        .replayed_frames = cam_replayed,
        .panel_pixels = pixels,
        .panel_width = w,
        .panel_height = h,
        .host_sink_lines = sink.host_lines,
        .position = setup.owner.session().currentPosition(),
        .ended = ended,
    };
}

/// Restore `setup` to its opening checkpoint and replay the same run slices
/// `driveSession` took (same instruction budget, same chunking) with host
/// output muted, so every host source is served from the history.
pub fn replayRun(allocator: std.mem.Allocator, setup: *served_setup.Served, sink: *ConsoleSink, options: cli.Options) !Outcome {
    sink.host_lines = 0;
    const plane = setup.owner.transport();
    const bridge = plane.history orelse return error.NoHistory;
    const facts = try bridge.facts(bridge.context);
    var first: ?@TypeOf(facts.checkpoints[0]) = null;
    for (facts.checkpoints) |cp| {
        if (cp.position.branch == 0 and (first == null or cp.position.r < first.?.position.r)) first = cp;
    }
    const cp0 = first orelse return error.NoCheckpoint;
    try plane.restoreBase(.{ .checkpoint = .{ .id = cp0.id, .object = cp0.object, .position = cp0.position } });

    const session = setup.owner.session();
    session.setReplaying(true);
    defer session.setReplaying(false);
    var remaining: u64 = @intCast(options.budgetFor(false));
    var ended: session_api.Ended = .count;
    while (remaining > 0 and ended == .count) {
        const step = if (sink.tap.waiting() != null or options.ms != null) @min(remaining, 50_000) else remaining;
        try session.setRunBudget(.cpu0, step);
        const before = setup.owner.primaryCpu().retired;
        const cmd: session_api.Run = if (!session.live.started) .run else .cont;
        ended = try session.run(.cpu0, cmd);
        const retired = setup.owner.primaryCpu().retired -| before;
        remaining -|= if (retired == 0) 1 else retired;
    }
    return captureOutcome(allocator, setup, sink, ended);
}

fn loadedBytes(image: elf.Image) u32 {
    var total: u32 = 0;
    for (0..image.segmentCount()) |i| {
        const seg = image.loadSegment(@intCast(i)) orelse continue;
        total +|= @intCast(seg.bytes.len);
    }
    return total;
}

/// Plain CLI entry point for `--camera-source` and `--history` runs.
pub fn run(allocator: std.mem.Allocator, io: std.Io, options: cli.Options) !u8 {
    var stdout = std.Io.File.stdout().writerStreaming(io, &.{});
    return runWithOut(allocator, io, options, &stdout.interface);
}

/// `run` writing its announce and end-of-run report to `out`.
pub fn runWithOut(allocator: std.mem.Allocator, io: std.Io, options: cli.Options, out: *std.Io.Writer) !u8 {
    if (validate(options)) |reason| {
        std.debug.print("{s}\n", .{reason});
        return 2;
    }
    const elf_bytes = std.Io.Dir.cwd().readFileAlloc(io, options.path, allocator, .limited(64 << 20)) catch |err| {
        std.debug.print("cannot open {s}: {s}\n", .{ options.path, @errorName(err) });
        return 1;
    };
    defer allocator.free(elf_bytes);

    var bridges = std.heap.ArenaAllocator.init(allocator);
    defer bridges.deinit();
    var setup: served_setup.Served = undefined;
    const vector_base = openSession(&setup, &bridges, allocator, io, elf_bytes, options) catch |err| {
        std.debug.print("session run refused: {s}\n", .{@errorName(err)});
        return if (err == error.NoVectors) 1 else 2;
    };
    defer setup.deinit();

    const board = setup.owner.board();
    if (options.console) board.console_input.source = cli.host.bytes.stdin();
    var sink: ConsoleSink = .{};
    sink.bind(&setup, io, options.console, options.until);

    try zig_main.announce(out, setup.owner.guest(), loadedBytes(setup.owner.image()), vector_base, false);

    const ended = try driveSession(&setup, &sink, options);
    try printEndReport(out, io, &setup, options);
    return switch (ended) {
        .core => 1,
        .stop => |s| switch (s) {
            .replay_failed => 1,
            else => 0,
        },
        .count => 0,
    };
}

fn printEndReport(out: *std.Io.Writer, io: std.Io, setup: *served_setup.Served, options: cli.Options) !void {
    const board = setup.owner.board();
    const guest = setup.owner.guest();
    const image = setup.owner.image();
    const pc = (try setup.owner.session().register(.cpu0, .pc)) & ~@as(u32, 1);
    try out.print("ran {d} instructions, pc 0x{X:0>8}\n", .{ setup.owner.primaryCpu().retired, pc });
    try report.bus(board, out);
    try report.blocks(board, out, setup.owner.state.edge.timebase);
    try report_dumps.dumpSymbols(out, io, guest, image, options);
    try mem_dump.printAll(out, guest, &board.bus, image, options.memDumps());
    try report_dumps.dumpRegisters(out, json_regs.Reader{ .zig = &setup.owner.primaryCpu().regs }, guest, options);
    try frame_out.report(out, io, board, options.frame_out, options.panel_only);
}
