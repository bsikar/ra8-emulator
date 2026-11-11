//! QTR-003 COMMON qualification tests: exact navigation matrix (`step`,
//! `stepBack`, redo, `seek` A -> B -> A, cancel-restores-origin, and canonical
//! branch fork interventions preserving parent branch future on fresh attach).
const std = @import("std");
const t = std.testing;
const ra8 = @import("ra8");
const oracle = @import("common_oracle.zig");
const fakes = @import("../history_fakes.zig");

const Harness = ra8.session.harness.Harness;
const transport = ra8.session.transport;
const seek_engine_mod = ra8.session.history_seek_engine;
const seek_facts_mod = ra8.session.history_seek_facts;
const touched_pages = ra8.session.history_touched_pages;
const branch_mod = ra8.session.history_branch;
const fork_router_mod = ra8.session.history_fork_router;
const position_mod = ra8.session.history_position;

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

fn same(a: oracle.Capture, b: oracle.Capture) !void {
    if (a.first(b)) |domain| {
        std.debug.print("COMMON nav divergence in domain: {s}\n", .{domain});
        return error.GuestDivergence;
    }
}

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(ctx: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(ctx));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

const NavBridge = struct {
    gpa: std.mem.Allocator,
    opened: *Harness,
    sink: *fakes.Sink,
    objects: *fakes.Objects,
    prior: ?seek_facts_mod.Facts = null,
    touched_list: std.ArrayList(*touched_pages.Touched) = .empty,

    fn bridge(self: *NavBridge) transport.Bridge {
        return .{ .context = self, .facts = facts, .restore = restore, .logBytes = logBytes };
    }

    fn logBytes(ctx: *anyopaque) anyerror![]const u8 {
        const self: *NavBridge = @ptrCast(@alignCast(ctx));
        return self.sink.bytes.items;
    }

    fn facts(ctx: *anyopaque) anyerror!seek_engine_mod.Facts {
        const self: *NavBridge = @ptrCast(@alignCast(ctx));
        if (self.prior) |old| self.gpa.free(old.checkpoints);
        for (self.touched_list.items) |tp| {
            tp.deinit();
            self.gpa.destroy(tp);
        }
        self.touched_list.clearRetainingCapacity();
        const gathered = try seek_facts_mod.gather(self.gpa, self.sink.bytes.items);
        self.prior = gathered;
        for (gathered.checkpoints) |*c| {
            const name = touched_pages.objectName(c.object);
            if (self.objects.get(&name)) |saved| {
                if (touched_pages.Touched.decodeSlice(self.gpa, saved)) |decoded| {
                    const ptr = try self.gpa.create(touched_pages.Touched);
                    ptr.* = decoded;
                    try self.touched_list.append(self.gpa, ptr);
                    c.touched = ptr;
                } else |_| {}
            }
        }
        const cur = if (self.opened.session().grid) |g| g.at else oracle.Position{};
        const win_facts: ?seek_engine_mod.WindowFacts = if (self.opened.session().window) |w|
            if (w.ready() and w.start() != null and w.end() != null and w.at() != null) .{
                .start = w.start().?,
                .end = w.end().?,
                .at = w.at().?,
                .line = w.line,
                .slots = w.count(),
            } else null
        else
            null;
        return .{ .current = cur, .checkpoints = gathered.checkpoints, .window = win_facts };
    }

    fn restore(ctx: *anyopaque, object: []const u8) anyerror!void {
        const self: *NavBridge = @ptrCast(@alignCast(ctx));
        const saved = self.objects.get(object) orelse return error.MissingObject;
        try self.opened.history().restoreBytes(saved);
    }

    fn deinit(self: *NavBridge) void {
        if (self.prior) |old| self.gpa.free(old.checkpoints);
        for (self.touched_list.items) |tp| {
            tp.deinit();
            self.gpa.destroy(tp);
        }
        self.touched_list.deinit(self.gpa);
    }
};

fn formatTarget(gpa: std.mem.Allocator, p: oracle.Position) ![]u8 {
    return std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{ p.r, @tagName(p.phase), p.o, @tagName(p.gap) });
}

fn pumpToFinish(tr: *transport.Transport, wall: *FakeWall, ticket: transport.Ticket) !void {
    var guards: usize = 0;
    while (guards < 100_000) : (guards += 1) {
        const p = try tr.pump(wall.wall(), wall.now_ns + 4_000_000);
        if (p.finished) |fin| {
            try t.expectEqual(ticket, fin.ticket);
            return;
        }
    }
    return error.TransportPumpTimeout;
}

const SeekPair = struct {
    pos_a: oracle.Position,
    pos_b: oracle.Position,
    cap_a: oracle.Capture,
    cap_b: oracle.Capture,
    b_object: [16]u8,
};

fn verifyStepAndSeekMatrix(h: *Harness, nav: *NavBridge, tr: *transport.Transport, wall: *FakeWall) !SeekPair {
    const sess = h.session();
    const pre_step = try oracle.capture(h);
    _ = try sess.step(.cpu0);
    const post_step = try oracle.capture(h);
    try t.expect(pre_step.first(post_step) != null);
    try sess.stepBack(.cpu0);
    try same(pre_step, try oracle.capture(h));
    try pumpToFinish(tr, wall, try tr.command(.{ .step = .{ .core = .cpu0, .count = 1, .dir = .fwd } }));
    try same(post_step, try oracle.capture(h));

    const gathered = try NavBridge.facts(nav);
    try t.expect(gathered.checkpoints.len >= 2);
    const pos_a = gathered.checkpoints[0].position;
    const last_cp = gathered.checkpoints[gathered.checkpoints.len - 1];
    const pos_b = last_cp.position;
    const txt_a = try formatTarget(t.allocator, pos_a);
    defer t.allocator.free(txt_a);
    const txt_b = try formatTarget(t.allocator, pos_b);
    defer t.allocator.free(txt_b);

    try pumpToFinish(tr, wall, try tr.command(.{ .seek = .{ .target = txt_a } }));
    const cap_a = try oracle.capture(h);
    try t.expectEqual(pos_a.r, h.grid().at.r);

    try pumpToFinish(tr, wall, try tr.command(.{ .seek = .{ .target = txt_b } }));
    const cap_b = try oracle.capture(h);
    try t.expectEqual(pos_b.r, h.grid().at.r);
    try t.expect(cap_a.first(cap_b) != null);

    try pumpToFinish(tr, wall, try tr.command(.{ .seek = .{ .target = txt_a } }));
    try same(cap_a, try oracle.capture(h));

    const pos_r1: oracle.Position = .{ .branch = 0, .r = pos_a.r, .phase = .cpu0, .o = 1, .gap = .retired };
    const txt_r1 = try formatTarget(t.allocator, pos_r1);
    defer t.allocator.free(txt_r1);
    try pumpToFinish(tr, wall, try tr.command(.{ .seek = .{ .target = txt_r1 } }));
    const cap_r1 = try oracle.capture(h);
    try t.expect(cap_a.first(cap_r1) != null);

    const pos_r2: oracle.Position = .{ .branch = 0, .r = pos_a.r, .phase = .cpu0, .o = 2, .gap = .retired };
    const txt_r2 = try formatTarget(t.allocator, pos_r2);
    defer t.allocator.free(txt_r2);
    try pumpToFinish(tr, wall, try tr.command(.{ .seek = .{ .target = txt_r2 } }));
    const cap_r2 = try oracle.capture(h);
    try t.expect(cap_r1.first(cap_r2) != null);

    try pumpToFinish(tr, wall, try tr.command(.{ .step = .{ .core = .cpu0, .dir = .back } }));
    try same(cap_r1, try oracle.capture(h));
    try pumpToFinish(tr, wall, try tr.command(.{ .step = .{ .core = .cpu0, .dir = .fwd } }));
    try same(cap_r2, try oracle.capture(h));

    try pumpToFinish(tr, wall, try tr.command(.{ .seek = .{ .target = txt_b } }));
    try same(cap_b, try oracle.capture(h));

    const rcont_ticket = try tr.command(.rcont);
    _ = try tr.command(.pause);
    try t.expectError(error.Cancelled, tr.finish(rcont_ticket, wall.wall(), null));
    try same(cap_b, try oracle.capture(h));

    return .{ .pos_a = pos_a, .pos_b = pos_b, .cap_a = cap_a, .cap_b = cap_b, .b_object = last_cp.object };
}

test "COMMON QTR-003 navigation matrix step stepBack redo seek A-B-A cancel and canonical branch fork" {
    var sink: fakes.Sink = .{ .gpa = t.allocator };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = t.allocator };
    defer objects.deinit();

    var h = try ra8.session.harness.open(t.allocator, t.io, .{
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
    try h.openWindow(8 * 1024 * 1024);

    const sess = h.session();
    var graph = try branch_mod.BranchGraph.init(t.allocator);
    defer graph.deinit();
    var router = fork_router_mod.ForkRouter.init(t.allocator, &graph);
    defer router.deinit();
    sess.attachForkRouter(&router);
    defer sess.fork_router = null;

    sess.live.budget = 50_000;
    _ = try sess.run(.cpu0, .cont);
    _ = try sess.run(.cpu0, .cont);
    _ = try sess.run(.cpu0, .cont);
    try h.state.persistent.?.recorder.force();

    var nav = NavBridge{ .gpa = t.allocator, .opened = &h, .sink = &sink, .objects = &objects };
    defer nav.deinit();
    const tr = h.transport();
    tr.history = nav.bridge();
    var wall = FakeWall{};

    const pair = try verifyStepAndSeekMatrix(&h, &nav, tr, &wall);

    const txt_a = try formatTarget(t.allocator, pair.pos_a);
    defer t.allocator.free(txt_a);
    try pumpToFinish(tr, &wall, try tr.command(.{ .seek = .{ .target = txt_a } }));
    try same(pair.cap_a, try oracle.capture(&h));

    try t.expectError(error.ForkNeedsConfirmation, sess.setRegister(.cpu0, .r0, 0xdead_beef));
    sess.cancelFork();
    try t.expectEqual(@as(u32, 0), router.active_line);
    try same(pair.cap_a, try oracle.capture(&h));

    try t.expectError(error.ForkNeedsConfirmation, sess.setRegister(.cpu0, .r0, 0x1234_5678));
    try sess.confirmFork();
    try t.expectEqual(@as(u32, 1), router.active_line);
    try t.expectEqual(@as(u32, 1), h.grid().at.branch);
    try t.expectEqual(@as(u32, 0x1234_5678), try sess.register(.cpu0, .r0));

    _ = try sess.step(.cpu0);
    const cap_child = try oracle.capture(&h);
    try t.expectEqual(@as(u32, 1), cap_child.position.branch);

    var b_name: [32]u8 = undefined;
    for (pair.b_object, 0..) |byte, i| _ = try std.fmt.bufPrint(b_name[i * 2 ..][0..2], "{x:0>2}", .{byte});
    const b_bytes = objects.get(&b_name) orelse return error.MissingParentFuture;
    var fresh = try ra8.session.harness.open(t.allocator, t.io, .{
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
        .elf_path = dfu_elf,
        .board_profile = compact_profile,
        .history_frames = 4,
        .idle_skip = false,
    });
    defer fresh.deinit();
    try fresh.history().restoreBytes(b_bytes);
    try same(pair.cap_b, try oracle.capture(&fresh));
}
