//! QTR-003 COMMON qualification tests: continuous event-hooked ITM, UART, and
//! lossless P6 PPM display frame streams across every boundary, plus straight
//! vs split vs random-budget equivalence and fresh-attach frame parity.
const std = @import("std");
const builtin = @import("builtin");
const t = std.testing;
const ra8 = @import("ra8");
const oracle = @import("common_oracle.zig");

const Harness = ra8.session.harness.Harness;
const glcdc = ra8.chip.periph.glcdc;
const tcon = ra8.chip.periph.glcdc.tcon;
const glcdc_sys = ra8.chip.periph.glcdc.sys;
const pdctr = ra8.chip.periph.pdctr;
const prcr = ra8.chip.periph.prcr;
const sci = ra8.chip.periph.sci;

const ipc_elf = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
const ipc1_elf = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf";
const threadx_elf = "tests/fixtures/threadx/threadx_stkof.elf";
const dfu_elf = "tests/fixtures/dfu/dfu_bootloader.elf";
const ui_elf = "tests/fixtures/display/ra8_ui.elf";
const ui_tap = "tests/fixtures/display/tap.input";

fn same(a: oracle.Capture, b: oracle.Capture) !void {
    if (a.first(b)) |domain| {
        std.debug.print("COMMON stream divergence in domain: {s}\n", .{domain});
        return error.GuestDivergence;
    }
}

/// Passive continuous observer hooked onto `event_stream`, ITM port, and
/// boundary `frame_tap.Tap` across every slice and boundary without mutating
/// any guest or debugger state.
pub const ContinuousTap = struct {
    allocator: std.mem.Allocator,
    h: *Harness,
    sub_id: usize,
    tap: ra8.board.frame_tap.Tap = undefined,
    itm_seen: [2]usize = .{ 0, 0 },
    output: oracle.Stream = .{},
    frames: oracle.Stream = .{},
    boundary_hits: u64 = 0,
    dropped_events: u64 = 0,

    pub fn attach(self: *ContinuousTap, allocator: std.mem.Allocator, h: *Harness) !void {
        const id = h.session().event_stream.subscribe() orelse return error.EventStreamFull;
        self.* = .{ .allocator = allocator, .h = h, .sub_id = id };
        self.tap = .{
            .io = t.io,
            .context = self,
            .captureFn = onBoundary,
            .interval_ns = 0,
        };
        h.board().addFrameTap(&self.tap);
    }

    pub fn detach(self: *ContinuousTap) void {
        self.h.board().removeFrameTap(&self.tap);
        self.h.session().event_stream.unsubscribe(self.sub_id);
    }

    fn onBoundary(ctx: *anyopaque, virtual_ns: u64) void {
        const self: *ContinuousTap = @ptrCast(@alignCast(ctx));
        self.boundary_hits += 1;
        self.drainEvents();
        const planes = &self.h.board().panel.planes;
        if (planes.image.pixels.len != 0) {
            self.frames.rawFrame(
                self.h.grid().at,
                virtual_ns,
                planes.image.width,
                planes.image.height,
                planes.image.pixels,
            );
        }
    }

    pub fn drainEvents(self: *ContinuousTap) void {
        var buf: [64]ra8.session.api.Event = undefined;
        while (true) {
            const rd = self.h.session().event_stream.read(self.sub_id, &buf) orelse break;
            self.dropped_events += rd.dropped;
            if (rd.count == 0) break;
            const at = self.h.grid().at;
            for (buf[0..rd.count]) |ev| {
                switch (ev.payload) {
                    .uart => |u| self.output.append(u.channel, at, ev.virtual_ns, &.{u.byte}),
                    .frame => |f| {
                        var tag_buf: [20]u8 = undefined;
                        std.mem.writeInt(u64, tag_buf[0..8], f.generation, .little);
                        std.mem.writeInt(u32, tag_buf[8..12], f.width, .little);
                        std.mem.writeInt(u32, tag_buf[12..16], f.height, .little);
                        std.mem.writeInt(u16, tag_buf[16..18], f.dirty.width, .little);
                        std.mem.writeInt(u16, tag_buf[18..20], f.dirty.height, .little);
                        self.frames.append(4, at, ev.virtual_ns, &tag_buf);
                    },
                    else => {},
                }
            }
        }
        self.sampleItmPassive();
    }

    fn sampleItmPassive(self: *ContinuousTap) void {
        const count: usize = if (self.h.state.files.pair != null) 2 else 1;
        const ns = self.h.board().time.base.now();
        for (0..count) |idx| {
            const core_id: ra8.session.api.Core = @fromBackingInt(@intCast(idx));
            const itm = self.h.session().itmPort(core_id) catch continue;
            if (itm.text.len > self.itm_seen[idx]) {
                const delta = itm.text.buffer[self.itm_seen[idx]..itm.text.len];
                self.output.append(@intCast(16 + idx), self.h.grid().at, ns, delta);
                self.itm_seen[idx] = itm.text.len;
            }
        }
    }

    pub fn captureLosslessPpm(self: *ContinuousTap) !void {
        var img = try self.h.session().frame(self.allocator);
        defer img.deinit(self.allocator);
        try t.expect(img.width > 0 and img.height > 0);
        try self.frames.frame(self.allocator, self.h.grid().at, img);
    }
};

fn runSlices(path: []const u8, second_path: ?[]const u8, budgets: []const usize) !struct { cap: oracle.Capture, out_digest: oracle.Digest } {
    var h = try ra8.session.harness.open(t.allocator, t.io, .{ .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops), .elf_path = path, .history_frames = 2 });
    defer h.deinit();
    var sec: ra8.session.cpu1.bringup.Cpu1 = .{};
    if (second_path) |p| try sec.open(t.allocator, t.io, ra8.host.session_files.reader(ra8.session.file_ops.Reader), &h, p);
    defer if (second_path != null) sec.close(t.allocator);

    var tap: ContinuousTap = undefined;
    try tap.attach(t.allocator, &h);
    defer tap.detach();

    for (budgets, 0..) |b, idx| {
        h.session().live.budget = b;
        const cmd: ra8.session.api.Run = if (idx == 0) .run else .cont;
        const res = try h.session().run(.cpu0, cmd);
        try t.expect(res == .count);
        tap.drainEvents();
    }
    try t.expectEqual(@as(u64, 0), tap.dropped_events);
    return .{ .cap = try oracle.capture(&h), .out_digest = tap.output.digest() };
}

test "COMMON QTR-003 straight vs split vs random-budget runs match whole state and continuous streams" {
    const straight = [_]usize{12_000};
    const even_split = [_]usize{ 2_000, 2_000, 2_000, 2_000, 2_000, 2_000 };
    const random_split = [_]usize{ 1_137, 2_411, 789, 3_053, 1_901, 2_709 };

    inline for (.{ .{ ipc_elf, @as(?[]const u8, ipc1_elf) }, .{ threadx_elf, @as(?[]const u8, null) } }) |pair| {
        const a = try runSlices(pair[0], pair[1], &straight);
        const b = try runSlices(pair[0], pair[1], &even_split);
        const c = try runSlices(pair[0], pair[1], &random_split);
        try same(a.cap, b.cap);
        try same(a.cap, c.cap);
        try t.expectEqual(a.out_digest, b.out_digest);
        try t.expectEqual(a.out_digest, c.out_digest);
    }
}

fn armGlcdc(board: *ra8.board.board.Board, width: u32, height: u32, argb: u32) void {
    board.protection.write(prcr.win_base, 2, prcr.unlockWord(pdctr.guard));
    board.domains.graphics.write(pdctr.Domain.graphics.base(), 1, 0);
    board.display.write(glcdc.win_base + tcon.off.sthb1, 4, width);
    board.display.write(glcdc.win_base + tcon.off.stvb1, 4, height);
    board.display.write(glcdc.win_base + glcdc.off.bg_en, 4, glcdc.field.bg_en);
    board.display.write(glcdc.win_base + glcdc_sys.off.panel_clk, 4, glcdc_sys.clock.enable);
    board.display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, argb);
}

fn writeSciConsole(board: *ra8.board.board.Board, text: []const u8) void {
    const base = sci.win_base + @as(u32, @intCast(sci.console_channel)) * sci.stride;
    board.serial.write(base + sci.off_ccr0, 4, 0x30);
    for (text) |ch| board.serial.write(base + sci.off_tdr, 1, ch);
}

test "COMMON QTR-003 continuous event-attached display PPM frames and UART ITM streams" {
    var h = try ra8.session.harness.open(t.allocator, t.io, .{
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
        .elf_path = dfu_elf,
        .panel_vsync = .{ .phase_ns = 1_000, .period_ns = 4_000 },
        .history_frames = 2,
    });
    defer h.deinit();

    var tap: ContinuousTap = undefined;
    try tap.attach(t.allocator, &h);
    defer tap.detach();

    armGlcdc(h.board(), 48, 32, 0xFF22_4466);
    h.session().live.budget = 6_000;
    _ = try h.session().run(.cpu0, .run);
    writeSciConsole(h.board(), "uart-frame-1\n");
    const itm = try h.session().itmPort(.cpu0);
    try itm.text.appendSlice("itm-frame-1\n");
    tap.drainEvents();
    try tap.captureLosslessPpm();

    h.board().display.write(glcdc.win_base + glcdc.off.bg_bgc, 4, 0xFF88_AA33);
    _ = try h.session().run(.cpu0, .cont);
    writeSciConsole(h.board(), "uart-frame-2\n");
    try itm.text.appendSlice("itm-frame-2\n");
    tap.drainEvents();
    try tap.captureLosslessPpm();

    try t.expect(tap.boundary_hits > 0);
    try t.expect(tap.frames.count >= 2);
    try t.expect(tap.output.count >= 4);
    try t.expectEqual(@as(u64, 0), tap.dropped_events);

    const before_cap = try oracle.capture(&h);
    var saved = std.Io.Writer.Allocating.init(t.allocator);
    defer saved.deinit();
    try h.state.files.writeTo(&saved.writer);

    var fresh = try ra8.session.harness.open(t.allocator, t.io, .{
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
        .elf_path = dfu_elf,
        .panel_vsync = .{ .phase_ns = 1_000, .period_ns = 4_000 },
        .history_frames = 2,
    });
    defer fresh.deinit();
    try fresh.state.files.readFrom(saved.written());
    try same(before_cap, try oracle.capture(&fresh));

    var img_live = try h.session().frame(t.allocator);
    defer img_live.deinit(t.allocator);
    var img_fresh = try fresh.session().frame(t.allocator);
    defer img_fresh.deinit(t.allocator);
    try t.expectEqual(@as(u32, 48), img_live.width);
    try t.expectEqual(@as(u32, 32), img_live.height);
    var s_live: oracle.Stream = .{};
    var s_fresh: oracle.Stream = .{};
    try s_live.frame(t.allocator, h.grid().at, img_live);
    try s_fresh.frame(t.allocator, fresh.grid().at, img_fresh);
    try t.expectEqual(s_live.digest(), s_fresh.digest());
}

test "COMMON QTR-003 full ra8_ui 1072x1448 e-paper settle and lossless PPM fresh-attach parity" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    var h = try ra8.session.harness.open(t.allocator, t.io, .{
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
        .elf_path = ui_elf,
        .input_script = ui_tap,
        .history_frames = 2,
    });
    defer h.deinit();
    var tap: ContinuousTap = undefined;
    try tap.attach(t.allocator, &h);
    defer tap.detach();

    try h.session().waitSettled(2_000_000_000);
    tap.drainEvents();
    try tap.captureLosslessPpm();
    try t.expect(tap.boundary_hits > 0 and tap.frames.count >= 2);

    const before_cap = try oracle.capture(&h);
    var saved = std.Io.Writer.Allocating.init(t.allocator);
    defer saved.deinit();
    try h.state.files.writeTo(&saved.writer);

    var fresh = try ra8.session.harness.open(t.allocator, t.io, .{
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
        .elf_path = ui_elf,
        .input_script = ui_tap,
        .history_frames = 2,
    });
    defer fresh.deinit();
    try fresh.state.files.readFrom(saved.written());
    try same(before_cap, try oracle.capture(&fresh));
}
