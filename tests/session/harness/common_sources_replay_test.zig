//! QTR-003 COMMON qualification tests: full `Harness` injectable sources
//! (synthetic camera + source switch, byte/pipe console input, storage media,
//! touch/button/plug/fault/memory interventions) record once and replay twice
//! identically with zero live callbacks, muted external output, and unchanged log.
const std = @import("std");
const ra8 = @import("ra8");
const oracle = @import("common_oracle.zig");
const fakes = @import("../history_fakes.zig");

const api = ra8.session.api;
const branch_mod = ra8.session.history_branch;
const fork_router_mod = ra8.session.history_fork_router;
const replay_mod = ra8.session.history_replay;
const feeder = ra8.session.history_replay_feeder;
const recorded_camera = ra8.session.board.recorded_camera;
const ceu = ra8.chip.periph.ceu;
const sci = ra8.chip.periph.sci;
const frame_source = ra8.chip.periph.frame_source;
const ByteSource = ra8.chip.periph.byte_source.ByteSource;

const dfu_elf = "tests/fixtures/dfu/dfu_bootloader.elf";
const compact_profile =
    \\version=1
    \\ospi=size:1048576,width:8,clock_hz:166666667,latency_cycles:8,burst:incrementing16
    \\sdram=size:1048576,width:32,clock_hz:133000000,latency_cycles:3,burst:incrementing16
    \\memory_window_cycles=1000000
    \\led=P600,0x001F,LED1 BLUE
    \\led=P303,0x07E0,LED2 GREEN
    \\led=PA07,0xF800,LED3 RED
    \\switch=P009,SW1
    \\switch=P008,SW2
    \\panel=ek_ra8d2
    \\companion=c6@uart:sci2
;
const cam_w: u32 = 32;
const cam_h: u32 = 24;
const cam_frame0: u32 = ra8.chip.core.memmap.sdram_base + 0x1000;
const cam_frame1: u32 = ra8.chip.core.memmap.sdram_base + 0x2000;
const sram_note: u32 = 0x2201_F000;

const SyntheticCam = struct {
    seed: u8 = 0x11,
    captures: u32 = 0,
    calls: u32 = 0,

    fn frameFn(ctx: *anyopaque, _: u64, _: frame_source.Shape) void {
        const self: *SyntheticCam = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        self.captures += 1;
    }

    fn fillFn(ctx: *anyopaque, row: u32, col: u32, out: []u8) void {
        const self: *SyntheticCam = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        for (out, 0..) |*b, i| {
            const x: u32 = col + @as(u32, @intCast(i));
            b.* = self.seed +% @as(u8, @truncate(self.captures *% 29 +% row *% 7 +% x *% 3));
        }
    }

    fn closeFn(_: *anyopaque) void {}

    const vtable = frame_source.FrameSource.VTable{ .frame = frameFn, .fill = fillFn, .close = closeFn };

    fn source(self: *SyntheticCam) frame_source.FrameSource {
        return .{ .context = self, .vtable = &vtable };
    }

    fn changeFn(ctx: *anyopaque, spec: []const u8) anyerror!void {
        const self: *SyntheticCam = @ptrCast(@alignCast(ctx));
        self.seed = if (std.mem.eql(u8, spec, "grid")) 0xA5 else 0x3C;
    }
};

const PipeInput = struct {
    chunks: [2][]const u8 = .{ "ping\n", "status\n" },
    index: usize = 0,
    reads: u32 = 0,

    fn readFn(ctx: usize, into: []u8) ?usize {
        const self: *PipeInput = @ptrFromInt(ctx);
        self.reads += 1;
        if (self.index >= self.chunks.len) return null;
        const msg = self.chunks[self.index];
        self.index += 1;
        @memcpy(into[0..msg.len], msg);
        return msg.len;
    }

    fn byteSource(self: *PipeInput) ByteSource {
        return .{ .context = @intFromPtr(self), .readFn = readFn };
    }
};

const HostStdout = struct {
    writes: u32 = 0,
    bytes: usize = 0,

    fn writeFn(ctx: ?*anyopaque, line: []const u8) anyerror!void {
        const self: *HostStdout = @ptrCast(@alignCast(ctx.?));
        self.writes += 1;
        self.bytes += line.len;
    }

    fn sink(self: *HostStdout) sci.line.Sink {
        return .{ .context = self, .writeFn = writeFn };
    }
};

fn sessionMuted(ctx: *anyopaque) bool {
    const sess: *api.Session = @ptrCast(@alignCast(ctx));
    return sess.outputMuted();
}

fn routePipe(ctx: *anyopaque, bytes: []const u8) void {
    const sess: *api.Session = @ptrCast(@alignCast(ctx));
    sess.consoleInput(.cpu0, bytes) catch {};
}

fn triggerCeuCapture(board: *ra8.board.board.Board, dst: u32) void {
    board.capture.write(ceu.win_base + ceu.off.capwr, 4, cam_w | (cam_h << ceu.field.vertical_shift));
    board.capture.write(ceu.win_base + ceu.off.cdwdr, 4, cam_w);
    board.capture.write(ceu.win_base + ceu.off.cdayr, 4, dst);
    board.capture.write(ceu.win_base + ceu.off.capsr, 4, ceu.field.capture_enable);
}

fn emitConsoleText(board: *ra8.board.board.Board, text: []const u8) void {
    const base = sci.win_base + @as(u32, @intCast(sci.console_channel)) * sci.stride;
    board.serial.write(base + sci.off_ccr0, 4, 0x30);
    for (text) |ch| board.serial.write(base + sci.off_tdr, 1, ch);
}

const FirstCheckpoint = struct {
    found: bool = false,
    object: [16]u8 = @splat(0),

    fn visit(self: *FirstCheckpoint, entry: replay_mod.Entry) anyerror!void {
        if (!self.found and entry == .checkpoint) {
            self.found = true;
            self.object = entry.checkpoint.checkpoint.object;
        }
    }
};

fn hexObjectName(digest: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = std.fmt.bufPrint(out[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }
    return out;
}

fn runExactInstructions(h: *ra8.session.harness.Harness, count: u64) !void {
    const sess = h.session();
    const cpu = h.primaryCpu();
    const target = cpu.retired + count;
    var guards: u32 = 0;
    while (cpu.retired < target and guards < 32) : (guards += 1) {
        try sess.setRunBudget(.cpu0, target - cpu.retired);
        _ = try sess.run(.cpu0, .cont);
    }
    try std.testing.expectEqual(target, cpu.retired);
    try sess.setRunBudget(.cpu0, 50_000);
}

fn runDeterministicGuestSlices(h: *ra8.session.harness.Harness, live: bool) !void {
    const sess = h.session();
    try runExactInstructions(h, 50_000);
    triggerCeuCapture(h.board(), cam_frame0);
    emitConsoleText(h.board(), "slice-1-ok\n");

    if (live) {
        const now = h.board().time.base.now();
        try sess.changeCamera(.cpu0, "grid");
        try sess.tap(.cpu0, now + 2_000, 96, 144);
        try sess.button(.cpu0, now + 4_000, .sw1);
    }
    try runExactInstructions(h, 50_000);
    triggerCeuCapture(h.board(), cam_frame1);

    if (live) {
        const gauge_ep: api.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
        try sess.plug(.cpu0, gauge_ep, ra8.components.parts.gauge_name);
        try sess.setFault(.cpu0, gauge_ep, .{ .nack_every = 3 });
        try sess.write(.cpu0, sram_note, "replay-twice-storage");
    }
    try runExactInstructions(h, 50_000);
    emitConsoleText(h.board(), "slice-3-done\n");
    try runExactInstructions(h, 10_000);
}

fn replayAndVerifyOnce(
    h: *ra8.session.harness.Harness,
    cp0_bytes: []const u8,
    sink: *fakes.Sink,
    graph: *branch_mod.BranchGraph,
    host_out: *HostStdout,
    live_cap: oracle.Capture,
    live_log_len: usize,
) !void {
    const sess = h.session();
    try h.history().restoreBytes(cp0_bytes);
    sess.stampLine();
    try std.testing.expect(sess.currentPosition().r < graph.get(0).?.recorded_end.r);

    var tripwire_cam: SyntheticCam = .{ .seed = 0xFF };
    const cam_port = recorded_camera.from(h.board().capture.source).?;
    cam_port.inner = tripwire_cam.source();
    cam_port.replayed = 0;
    cam_port.failed = null;
    sess.attachCamera(.{ .context = &tripwire_cam, .changeFn = SyntheticCam.changeFn });

    var tripwire_pipe: PipeInput = .{ .chunks = .{ "WRONG\n", "WRONG\n" } };
    h.board().console_input.source = tripwire_pipe.byteSource();
    h.board().console_input.hook = .{ .context = sess, .feedFn = routePipe, .heldFn = sessionMuted };
    host_out.writes = 0;

    try feeder.loadSessionInterventions(sess, sink.bytes.items, .at);
    defer feeder.release(sess);

    try runDeterministicGuestSlices(h, false);

    try std.testing.expectEqual(@as(u32, 0), tripwire_cam.calls);
    try std.testing.expectEqual(@as(u64, 2), cam_port.replayed);
    try std.testing.expectEqual(@as(?anyerror, null), cam_port.failed);
    try std.testing.expectEqual(@as(u32, 0), tripwire_pipe.reads);
    try std.testing.expectEqual(@as(u32, 0), host_out.writes);
    try std.testing.expectEqual(live_log_len, sink.bytes.items.len);

    const replay_cap = try oracle.capture(h);
    if (live_cap.first(replay_cap)) |bad| {
        std.debug.print("COMMON replay mismatch in domain: {s}\n", .{bad});
        return error.ReplayStateMismatch;
    }
}

test "COMMON QTR-003: full Harness injectable sources and interventions record once and replay twice identically" {
    const gpa = std.testing.allocator;
    var sink: fakes.Sink = .{ .gpa = gpa };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = gpa };
    defer objects.deinit();

    var h = try ra8.session.harness.open(gpa, std.testing.io, .{
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
        .elf_path = dfu_elf,
        .board_profile = compact_profile,
        .history_frames = 4,
        .checkpoint_every = 1,
        .idle_skip = false,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer h.deinit();
    const sess = h.session();
    var graph = try branch_mod.BranchGraph.init(gpa);
    defer graph.deinit();
    var router = fork_router_mod.ForkRouter.init(gpa, &graph);
    defer router.deinit();
    sess.attachForkRouter(&router);
    defer sess.fork_router = null;

    var sd_block: [512]u8 = @splat(0x5A);
    try std.testing.expect(h.board().host_card.img.write(3, &sd_block));
    try h.board().nor.program(0x100, 0x33);
    var usb_disk: [512]u8 = @splat(0);
    usb_disk[0x40] = 0x77;
    h.board().usb.stick.disk = &usb_disk;
    defer h.board().usb.stick.disk = &.{};

    var live_cam: SyntheticCam = .{};
    h.board().capture.source.close();
    h.board().capture.source = live_cam.source();
    try recorded_camera.attach(gpa, sess, h.board());
    sess.attachCamera(.{ .context = &live_cam, .changeFn = SyntheticCam.changeFn });

    var host_out: HostStdout = .{};
    h.board().serial.line.setSink(host_out.sink());
    h.board().console_input.hook = .{ .context = sess, .feedFn = routePipe, .heldFn = sessionMuted };

    try runExactInstructions(&h, 50_000);
    if (sess.persistent_recorder) |rec| try rec.force();

    var cp0: FirstCheckpoint = .{};
    _ = try replay_mod.replay(sink.bytes.items, &cp0, FirstCheckpoint.visit);
    try std.testing.expect(cp0.found);
    const cp0_name = hexObjectName(cp0.object);
    const cp0_bytes = objects.get(&cp0_name) orelse return error.MissingCheckpoint;

    var live_pipe: PipeInput = .{};
    h.board().console_input.source = live_pipe.byteSource();
    try runDeterministicGuestSlices(&h, true);
    if (sess.persistent_recorder) |rec| try rec.force();

    try std.testing.expect(live_cam.calls > 0 and live_pipe.reads > 0 and host_out.writes >= 2);
    const live_cap = try oracle.capture(&h);
    const live_log_len = sink.bytes.items.len;

    var f0: [cam_w * cam_h]u8 = undefined;
    var f1: [cam_w * cam_h]u8 = undefined;
    try sess.read(.cpu0, cam_frame0, &f0);
    try sess.read(.cpu0, cam_frame1, &f1);
    try std.testing.expect(!std.mem.eql(u8, &f0, &f1));

    for (0..2) |_| {
        try replayAndVerifyOnce(&h, cp0_bytes, &sink, &graph, &host_out, live_cap, live_log_len);
        var rf0: [cam_w * cam_h]u8 = undefined;
        var rf1: [cam_w * cam_h]u8 = undefined;
        try sess.read(.cpu0, cam_frame0, &rf0);
        try sess.read(.cpu0, cam_frame1, &rf1);
        try std.testing.expectEqualSlices(u8, &f0, &rf0);
        try std.testing.expectEqualSlices(u8, &f1, &rf1);
    }
}
