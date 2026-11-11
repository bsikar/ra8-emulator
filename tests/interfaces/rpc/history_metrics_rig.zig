//! Qualification rig for RA8EMU-1234 Item 3 (F02 / F13): matched off/on
//! recording overhead and reverse-window / checkpoint / seek latencies.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const setup = ra8.rpc.served_setup;
const transport = ra8.session.transport;
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_sys = ra8.chip.periph.glcdc.sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;

pub const mib: u64 = 1024 * 1024;
pub const ui_image = "tests/fixtures/display/ra8_ui.elf";
pub const compute_image = "tests/fixtures/profile/call_tree.elf";
pub const poll_image = "tests/fixtures/plug/gauge_poll.elf";
pub const mve_image = "tests/fixtures/fpu/dsp.elf";
pub const dual_image = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
pub const dual_second = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");

pub const OverheadResult = struct {
    pairs: usize,
    rounds: u64,
    checkpoints: u32,
    median_off_ns: u64,
    median_on_ns: u64,
    median_pct: f64,
    ram_pct: f64,
};

pub const LatencyResult = struct {
    window_undo_ns: u64,
    nearby_seek_ns: u64,
    hot_checkpoint_ns: u64,
    stage2_seek_ns: u64,
    first_reverse_frame_ns: u64,
    pause_ns: u64,
};

pub const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 16_666_666;
        return self.now_ns;
    }
    pub fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

const ConsoleTap = struct {
    hasher: std.crypto.hash.Blake3 = .init(.{}),
    fn feed(context: *anyopaque, data: []const u8) anyerror!void {
        const self: *ConsoleTap = @ptrCast(@alignCast(context));
        self.hasher.update(data);
    }
};

const RunOutcome = struct {
    elapsed_ns: u64,
    rounds: u64,
    checkpoints: u32,
    machine_digest: [32]u8,
    console_digest: [32]u8,
    frame_digest: [32]u8,
};

pub fn nowAwake(io: std.Io) u64 {
    return @intCast(@max(0, std.Io.Timestamp.now(io, .awake).nanoseconds));
}

pub fn showColor(board: anytype, color: u32) void {
    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, 2);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, 1);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, color);
}

fn digestMachine(gpa: std.mem.Allocator, served: *setup.Served) ![32]u8 {
    var snap: std.Io.Writer.Allocating = try .initCapacity(gpa, 65536);
    defer snap.deinit();
    const state_file: *ra8.session.harness.files.StateFile = @ptrCast(@alignCast(served.owner.stateFiles().context));
    try state_file.files.writeTo(&snap.writer);
    var out: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(snap.written(), &out, .{});
    return out;
}

fn digestFrame(gpa: std.mem.Allocator, served: *setup.Served) ![32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    const disp = &served.owner.board().display;
    const count = @as(usize, disp.panelWidth()) * disp.panelHeight();
    if (count > 0) if (disp.compositeInputs()) |input| {
        const argb = try gpa.alloc(u32, count);
        defer gpa.free(argb);
        if (disp.composite(input, disp.domain.powered(), argb) == .picture) {
            hasher.update(std.mem.sliceAsBytes(argb));
        }
    };
    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn runTimed(gpa: std.mem.Allocator, io: std.Io, opts: ?setup.HistoryOpts, target_rounds: u64, slice_budget: u64) !RunOutcome {
    var served: setup.Served = undefined;
    try served.open(gpa, io, ui_image, null, opts);
    defer served.deinit();
    const session = served.owner.session();
    var tap: ConsoleTap = .{};
    session.attachConsole(.{ .context = &tap, .feedFn = ConsoleTap.feed });
    showColor(served.owner.board(), 0xFF18_3456);
    try session.setRunBudget(.cpu0, slice_budget);

    const start_ns = nowAwake(io);
    var first = true;
    var guard: usize = 0;
    while (session.currentPosition().r < target_rounds and guard < 100_000) : (guard += 1) {
        if (session.currentPosition().r == target_rounds / 2) {
            served.owner.board().display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF65_4321);
        }
        _ = try session.run(.cpu0, if (first) .run else .cont);
        first = false;
    }
    try served.flushHistory();
    const elapsed_ns = nowAwake(io) -| start_ns;

    var console_digest: [32]u8 = undefined;
    tap.hasher.final(&console_digest);
    const cp_count: u32 = if (session.live.checkpoints) |cp| cp.next_id else 0;
    return .{
        .elapsed_ns = elapsed_ns,
        .rounds = session.currentPosition().r,
        .checkpoints = cp_count,
        .machine_digest = try digestMachine(gpa, &served),
        .console_digest = console_digest,
        .frame_digest = try digestFrame(gpa, &served),
    };
}

pub const TempRoot = struct {
    tmp: ?std.testing.TmpDir = null,
    linux_sub: ?[32]u8 = null,
    path: [:0]u8,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, seed: u64) !TempRoot {
        if (builtin.os.tag == .linux) {
            if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |tmp_base_val| {
                var tmp_base = tmp_base_val;
                defer tmp_base.close(io);
                var sub: [32]u8 = undefined;
                const mix = std.hash.Wyhash.hash(seed, std.mem.asBytes(&nowAwake(io)));
                const name = try std.fmt.bufPrint(&sub, "ra8-ovh-{x:0>16}", .{mix});
                var pad: [32]u8 = @splat(0);
                @memcpy(pad[0..name.len], name);
                tmp_base.deleteTree(io, name) catch {};
                try tmp_base.createDir(io, name, .default_dir);
                return .{ .linux_sub = pad, .path = try std.fmt.allocPrintSentinel(gpa, "/tmp/{s}", .{name}, 0) };
            } else |_| {}
        }
        var t = std.testing.tmpDir(.{});
        errdefer t.cleanup();
        return .{ .tmp = t, .path = try t.dir.realPathFileAlloc(io, ".", gpa) };
    }

    pub fn close(self: *TempRoot, gpa: std.mem.Allocator, io: std.Io) void {
        gpa.free(self.path);
        if (self.linux_sub) |pad| {
            const name = std.mem.sliceTo(&pad, 0);
            if (std.Io.Dir.openDirAbsolute(io, "/tmp", .{})) |tmp_base_val| {
                var tmp_base = tmp_base_val;
                defer tmp_base.close(io);
                tmp_base.deleteTree(io, name) catch {};
            } else |_| {}
        }
        if (self.tmp) |*t| t.cleanup();
    }
};

pub fn measureOverhead(gpa: std.mem.Allocator, io: std.Io, target_rounds: u64, slice_budget: u64, pairs: usize) !OverheadResult {
    try std.testing.expect(pairs >= 1);
    var warm_tmp = try TempRoot.open(gpa, io, 0x99);
    defer warm_tmp.close(gpa, io);
    _ = try runTimed(gpa, io, null, @min(target_rounds, 128), slice_budget);
    _ = try runTimed(gpa, io, .{ .root = warm_tmp.path, .checkpoint_every = 64 }, @min(target_rounds, 128), slice_budget);

    var off_samples = try gpa.alloc(u64, pairs);
    defer gpa.free(off_samples);
    var on_samples = try gpa.alloc(u64, pairs);
    defer gpa.free(on_samples);
    var pct_samples = try gpa.alloc(f64, pairs);
    defer gpa.free(pct_samples);

    var rounds_seen: u64 = 0;
    var cps_seen: u32 = 0;
    for (0..pairs) |idx| {
        var temp = try TempRoot.open(gpa, io, idx + 1);
        defer temp.close(gpa, io);

        const off = try runTimed(gpa, io, null, target_rounds, slice_budget);
        const on = try runTimed(gpa, io, .{ .root = temp.path, .checkpoint_every = 64 }, target_rounds, slice_budget);
        try std.testing.expectEqual(off.rounds, on.rounds);
        try std.testing.expectEqualSlices(u8, &off.machine_digest, &on.machine_digest);
        try std.testing.expectEqualSlices(u8, &off.console_digest, &on.console_digest);
        try std.testing.expectEqualSlices(u8, &off.frame_digest, &on.frame_digest);

        off_samples[idx] = off.elapsed_ns;
        on_samples[idx] = on.elapsed_ns;
        pct_samples[idx] = (@as(f64, @floatFromInt(on.elapsed_ns)) - @as(f64, @floatFromInt(off.elapsed_ns))) * 100.0 / @as(f64, @floatFromInt(@max(off.elapsed_ns, 1)));
        rounds_seen = on.rounds;
        cps_seen = on.checkpoints;
        if (builtin.mode == .fast) {
            std.debug.print("[metric] overhead_pair idx={d} rounds={d} cps={d} off_ms={d:.3} on_ms={d:.3} pct={d:.2}\n", .{
                idx, on.rounds, on.checkpoints, @as(f64, @floatFromInt(off.elapsed_ns)) / 1e6, @as(f64, @floatFromInt(on.elapsed_ns)) / 1e6, pct_samples[idx],
            });
        }
    }

    const ram_off = try runTimed(gpa, io, null, target_rounds, slice_budget);
    const ram_on = try runTimed(gpa, io, .{ .checkpoint_every = 64, .ram_budget = 256 * mib }, target_rounds, slice_budget);
    try std.testing.expectEqualSlices(u8, &ram_off.machine_digest, &ram_on.machine_digest);
    const ram_pct = (@as(f64, @floatFromInt(ram_on.elapsed_ns)) - @as(f64, @floatFromInt(ram_off.elapsed_ns))) * 100.0 / @as(f64, @floatFromInt(@max(ram_off.elapsed_ns, 1)));

    std.mem.sort(u64, off_samples, {}, std.sort.asc(u64));
    std.mem.sort(u64, on_samples, {}, std.sort.asc(u64));
    std.mem.sort(f64, pct_samples, {}, std.sort.asc(f64));
    return .{
        .pairs = pairs,
        .rounds = rounds_seen,
        .checkpoints = cps_seen,
        .median_off_ns = off_samples[pairs / 2],
        .median_on_ns = on_samples[pairs / 2],
        .median_pct = pct_samples[pairs / 2],
        .ram_pct = ram_pct,
    };
}

pub const RealWall = struct {
    io: std.Io,
    fn now(context: *anyopaque) u64 {
        const self: *RealWall = @ptrCast(@alignCast(context));
        return nowAwake(self.io);
    }
    pub fn wall(self: *RealWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

pub fn driveTicket(io: std.Io, t: *transport.Transport, ticket: transport.Ticket) !void {
    var rw: RealWall = .{ .io = io };
    _ = try t.finish(ticket, rw.wall(), null);
}

fn measureWindowAndSeek(io: std.Io, served: *setup.Served, target_rounds: u64, out: *LatencyResult) !void {
    const session = served.owner.session();
    const t = served.owner.transport();
    const step_ticket = try t.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .back } });
    try driveTicket(io, t, step_ticket);
    const win = session.window.?;
    try std.testing.expect(win.ready() and win.cursor() >= 2);

    const t0_undo = nowAwake(io);
    try std.testing.expect(try win.undo());
    out.window_undo_ns = nowAwake(io) -| t0_undo;

    const target_idx = win.cursor() / 2;
    try std.testing.expect(win.cursor() - target_idx < 200_000);
    const near_pos = win.slotAt(target_idx).pre;
    var near_buf: [96]u8 = undefined;
    const near_spec = try std.fmt.bufPrint(&near_buf, "{d}:{d}:{s}:{d}:{s}", .{ near_pos.branch, near_pos.r, @tagName(near_pos.phase), near_pos.o, @tagName(near_pos.gap) });
    const t0_near = nowAwake(io);
    const near_ticket = try t.command(.{ .seek = .{ .target = near_spec } });
    try driveTicket(io, t, near_ticket);
    out.nearby_seek_ns = nowAwake(io) -| t0_near;
    try std.testing.expectEqual(near_pos, session.currentPosition());

    const bridge = t.history.?;
    const facts = try bridge.facts(bridge.context);
    try std.testing.expect(facts.checkpoints.len >= 2);
    const cp = facts.checkpoints[facts.checkpoints.len - 1];
    const t0_hot = nowAwake(io);
    try t.restoreBase(.{ .checkpoint = .{ .id = cp.id, .object = cp.object, .position = cp.position } });
    out.hot_checkpoint_ns = nowAwake(io) -| t0_hot;
    try std.testing.expectEqual(cp.position, session.currentPosition());

    session.dropWindow();
    const stage2_r: u64 = if (fullScaleRounds(target_rounds)) 115 else 32;
    var stage2_buf: [64]u8 = undefined;
    const stage2_spec = try std.fmt.bufPrint(&stage2_buf, "0:{d}:cpu0:0:retired", .{stage2_r});
    const t0_stage2 = nowAwake(io);
    const s2_ticket = try t.command(.{ .seek = .{ .target = stage2_spec } });
    try driveTicket(io, t, s2_ticket);
    out.stage2_seek_ns = nowAwake(io) -| t0_stage2;
    try std.testing.expectEqual(stage2_r, session.currentPosition().r);
}

fn fullScaleRounds(target_rounds: u64) bool {
    return target_rounds >= 128;
}

pub fn measureLatencies(gpa: std.mem.Allocator, io: std.Io, full_scale: bool) !LatencyResult {
    var temp = try TempRoot.open(gpa, io, 0x201);
    defer temp.close(gpa, io);
    const root = temp.path;

    var served: setup.Served = undefined;
    try served.open(gpa, io, ui_image, null, .{ .root = root, .checkpoint_every = 64, .frame_hz = 0 });
    defer served.deinit();
    const session = served.owner.session();
    const board = served.owner.board();
    showColor(board, 0xFF11_2233);
    try session.setRunBudget(.cpu0, 16_000);

    const target_rounds: u64 = if (full_scale) 192 else 64;
    var first = true;
    while (session.currentPosition().r < target_rounds) {
        if (session.currentPosition().r == 65) board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFFAA_BBCC);
        _ = try session.run(.cpu0, if (first) .run else .cont);
        first = false;
    }
    for (0..32) |_| _ = try session.run(.cpu0, .step);
    try served.flushHistory();
    var tries: usize = 0;
    while (served.frameCache().?.count() < 1 and tries < 500) : (tries += 1) try io.sleep(.fromMilliseconds(1), .awake);

    const t = served.owner.transport();
    const rewind = session.smooth_rewind.?;
    var wall: FakeWall = .{};
    var out: LatencyResult = .{ .window_undo_ns = 0, .nearby_seek_ns = 0, .hot_checkpoint_ns = 0, .stage2_seek_ns = 0, .first_reverse_frame_ns = 0, .pause_ns = 0 };

    try measureWindowAndSeek(io, &served, target_rounds, &out);

    const t0_frame = nowAwake(io);
    _ = try t.command(.{ .play = .{ .dir = .back, .speed = 0.05 } });
    for (0..8) |_| {
        if (rewind.current_frame != null) break;
        _ = try t.pump(wall.wall(), wall.now_ns + 20_000_000);
    }
    out.first_reverse_frame_ns = nowAwake(io) -| t0_frame;
    try std.testing.expect(rewind.current_frame != null);

    const t0_pause = nowAwake(io);
    _ = try t.command(.pause);
    out.pause_ns = nowAwake(io) -| t0_pause;
    try std.testing.expect(!rewind.isBusy());
    return out;
}
