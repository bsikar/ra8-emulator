//! Trace streaming and 1-by-1 RTOS trace sequence parity (RA8EMU-840,
//! RA8EMU-1234): wire `trace` events match `--trace-rtos-out` files 1-by-1
//! across dual-core ThreadX, `cpu1_pingpong_ipc`, split vs unsplit budgets,
//! mid-stretch breakpoint/step pauses, SysTick stretch cuts, snapshot
//! save/restore continuations, independent concurrent sessions, and negative
//! controls.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const rig_mod = @import("timeline_trace_rig.zig");

const proto = rig_mod.proto;
const rtos_trace = rig_mod.rtos_trace;
const Rig = rig_mod.Rig;
const Got = rig_mod.Got;
const accepted = rig_mod.accepted;
const eventOf = rig_mod.eventOf;
const compareSequence = rig_mod.compareSequence;
const compareWireToWire = rig_mod.compareWireToWire;

const dual0 = test_paths.threadx_dual;
const dual1 = test_paths.threadx_dual_cpu1;
const two_threads = test_paths.two_threads;
const stkof_elf = "tests/fixtures/threadx/threadx_stkof.elf";
const ipc0_elf = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
const ipc1_elf = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf";

test "wire trace matches every recorded event on both cores" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rig: Rig = .{};
    try rig.open(gpa, dual0, dual1, null);
    defer rig.deinit();
    try rig.subscribeBoth();
    for (0..2) |_| {
        try rig.runBudget(.cpu0, 60_000);
        try rig.runBudget(.cpu1, 60_000);
    }
    try std.testing.expect(rig.wire.got.items.len > 0);

    const stats = try rig.verifyBothCores(gpa, tmp.dir, "dual.txt");
    for (stats) |s| {
        try std.testing.expect(s.switches > 0 and s.enters > 0 and s.leaves > 0 and s.idles > 0);
        try std.testing.expect(s.equal_pos > 0);
    }

    // Each core's recorded file must match the wire in order and in all
    // payload fields, not just the number of trace notifications.
    for ([_]u1{ 0, 1 }) |core_index| {
        const got = try rig.recordedCore(gpa, tmp.dir, "dual_wire.txt", core_index);
        defer gpa.free(got);
        var cursor: usize = 0;
        for (rig.wire.got.items) |one| {
            if ((one.core == .cpu0) != (core_index == 0)) continue;
            try std.testing.expect(cursor < got.len);
            try std.testing.expectEqualDeep(got[cursor], eventOf(one));
            cursor += 1;
        }
        try std.testing.expectEqual(got.len, cursor);
        try expectActivity(got);
    }
}

fn expectActivity(events: []const rtos_trace.Event) !void {
    var switches: usize = 0;
    var enters: usize = 0;
    var idles: usize = 0;
    for (events) |one| switch (one.kind) {
        .switch_to => switches += 1,
        .idle => idles += 1,
        .enter => enters += 1,
        .leave => {},
    };
    try std.testing.expect(switches > 0);
    try std.testing.expect(enters > 0);
    try std.testing.expect(idles > 0);
}

test "dual-core ThreadX split and unsplit budgets produce identical 1-by-1 sequences" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var unsplit: Rig = .{};
    try unsplit.open(gpa, dual0, dual1, null);
    defer unsplit.deinit();
    try unsplit.subscribeBoth();
    try unsplit.runSplit(.cpu0, &.{ 60_000, 60_000 });

    var split: Rig = .{};
    try split.open(gpa, dual0, dual1, null);
    defer split.deinit();
    try split.subscribeBoth();
    // Sums to 120_000 across sub-stretch, exact-50_000-cadence, and cross-stretch slices.
    try split.runSplit(.cpu0, &.{ 1, 17, 511, 4_471, 20_000, 25_000, 19_999, 50_001 });

    const s_unsplit = try unsplit.verifyBothCores(gpa, tmp.dir, "unsplit.txt");
    const s_split = try split.verifyBothCores(gpa, tmp.dir, "split.txt");
    try std.testing.expectEqual(s_unsplit, s_split);
    try std.testing.expect(s_split[0].equal_pos > 0 and s_split[1].equal_pos > 0);
    try compareWireToWire(unsplit.wire.got.items, split.wire.got.items);
}

test "cpu1_pingpong_ipc bare-metal and mixed dual-core sessions preserve 1-by-1 trace boundaries" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Pure bare-metal IPC pair: trace subscription refuses cleanly, and split
    // vs unsplit runs complete IPC ping-pong with zero bogus trace events.
    var pure_unsplit: Rig = .{};
    try pure_unsplit.open(gpa, ipc0_elf, ipc1_elf, null);
    defer pure_unsplit.deinit();
    try std.testing.expect((try pure_unsplit.wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .trace })) == .err);
    try std.testing.expect((try pure_unsplit.wire.call(proto.Subscription, .subscribe, .{ .core = .cpu1, .topic = .trace })) == .err);
    try pure_unsplit.runSplit(.cpu0, &.{ 60_000, 65_987 });

    var pure_split: Rig = .{};
    try pure_split.open(gpa, ipc0_elf, ipc1_elf, null);
    defer pure_split.deinit();
    try pure_split.runSplit(.cpu0, &.{ 313, 1024, 4999, 19_651, 50_000, 50_000 });
    try std.testing.expectEqual(@as(usize, 0), pure_unsplit.wire.got.items.len);
    try std.testing.expectEqual(@as(usize, 0), pure_split.wire.got.items.len);
    try std.testing.expect(pure_split.served.owner.board().mailbox.channels[2].pushes > 0);
    try std.testing.expect(pure_split.served.owner.board().mailbox.channels[0].pops > 0);
    try std.testing.expectEqual(pure_unsplit.served.second.?.cpu().retired, pure_split.served.second.?.cpu().retired);

    // Mixed: cpu1_pingpong_ipc (CPU0 Secure->NS) + threadx_dual_cpu1 (CPU1 RTOS), unsplit vs split.
    var mix_a: Rig = .{};
    try mix_a.open(gpa, ipc0_elf, dual1, null);
    defer mix_a.deinit();
    try mix_a.subscribeBoth();
    try mix_a.runSplit(.cpu0, &.{ 60_000, 60_000 });

    var mix_b: Rig = .{};
    try mix_b.open(gpa, ipc0_elf, dual1, null);
    defer mix_b.deinit();
    try mix_b.subscribeBoth();
    try mix_b.runSplit(.cpu0, &.{ 37, 4_963, 25_000, 20_000, 19_999, 50_001 });

    const stats_a = try mix_a.verifyBothCores(gpa, tmp.dir, "mix_a.txt");
    const stats_b = try mix_b.verifyBothCores(gpa, tmp.dir, "mix_b.txt");
    try std.testing.expectEqual(@as(usize, 0), stats_a[0].total);
    try std.testing.expect(stats_a[1].switches > 0 and stats_a[1].enters > 0 and stats_a[1].equal_pos > 0);
    try std.testing.expectEqual(stats_a, stats_b);
    try compareWireToWire(mix_a.wire.got.items, mix_b.wire.got.items);

    // Reverse mixed: threadx_dual (CPU0 RTOS) + cpu1_pingpong_ipc_cpu1 (CPU1 bare-metal).
    var mix_rev: Rig = .{};
    try mix_rev.open(gpa, dual0, ipc1_elf, null);
    defer mix_rev.deinit();
    try mix_rev.subscribeBoth();
    try mix_rev.runSplit(.cpu0, &.{ 73, 4_927, 25_000, 30_000 });
    const stats_rev = try mix_rev.verifyBothCores(gpa, tmp.dir, "mix_rev.txt");
    try std.testing.expect(stats_rev[0].switches > 0 and stats_rev[0].enters > 0 and stats_rev[0].equal_pos > 0);
    try std.testing.expectEqual(@as(usize, 0), stats_rev[1].total);
}

test "mid-stretch pause via breakpoint and single-step preserves 1-by-1 trace sequence" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var straight: Rig = .{};
    try straight.open(gpa, dual0, dual1, null);
    defer straight.deinit();
    try straight.subscribeBoth();
    try straight.runSplit(.cpu0, &.{ 60_000, 60_000 });

    var paused: Rig = .{};
    try paused.open(gpa, dual0, dual1, null);
    defer paused.deinit();
    try paused.subscribeBoth();

    const svc_at = (ra8.session.symbols.addressOf(paused.served.owner.image(), "SVCall_Handler") orelse return error.MissingSymbol) & ~@as(u32, 1);
    const bp = try paused.wire.callDecode(proto.Point, proto.U32, .set_breakpoint, .{ .core = .cpu0, .address = svc_at });
    try paused.runBudget(.cpu0, 10_000);
    // Stopped mid-stretch at SVCall_Handler: observe already flushed ISR entry onto wire.
    try std.testing.expect(paused.served.owner.grid().stretch.carry > 0);
    try std.testing.expect(paused.served.owner.grid().stretch.left() > 0);
    try std.testing.expect(paused.wire.got.items.len >= 2);
    try accepted(try paused.wire.call(proto.PointId, .clear_breakpoint, .{ .core = .cpu0, .id = bp.value }));

    for (0..5) |_| try accepted(try paused.wire.call(proto.CoreOnly, .step, .{ .core = .cpu0 }));
    for (0..3) |_| try accepted(try paused.wire.call(proto.CoreOnly, .step, .{ .core = .cpu1 }));
    try accepted(try paused.wire.call(proto.CoreOnly, .pause, .{ .core = .cpu0 }));
    const used = paused.served.owner.primaryCpu().slots;
    try std.testing.expect(used < 120_000);
    try paused.runBudget(.cpu0, 120_000 - used);

    const s_straight = try straight.verifyBothCores(gpa, tmp.dir, "straight.txt");
    const s_paused = try paused.verifyBothCores(gpa, tmp.dir, "paused.txt");
    try std.testing.expectEqual(s_straight, s_paused);
    for ([_]proto.Core{ .cpu0, .cpu1 }) |core| {
        const w_a = try straight.wire.forCore(gpa, core);
        defer gpa.free(w_a);
        const w_b = try paused.wire.forCore(gpa, core);
        defer gpa.free(w_b);
        try compareWireToWire(w_a, w_b);
    }
}

test "SysTick arming cut and CGC rate shift preserve 1-by-1 normalized trace sequence" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var unsplit: Rig = .{};
    try unsplit.open(gpa, stkof_elf, ipc1_elf, null);
    defer unsplit.deinit();
    try unsplit.subscribeBoth();
    try unsplit.runSplit(.cpu0, &.{ 60_000, 60_000 });

    var split: Rig = .{};
    try split.open(gpa, stkof_elf, ipc1_elf, null);
    defer split.deinit();
    try split.subscribeBoth();
    try split.runSplit(.cpu0, &.{ 19, 109, 512, 1024, 2336, 16_000, 40_000, 60_000 });

    // threadx_stkof runs ra8_cgc_init and arms SysTick inside _tx_initialize_kernel_enter,
    // firing systick_cut mid-stretch before switching to overflow and entering UsageFault.
    try std.testing.expect(split.served.owner.state.edge.timebase.rearms > 0);
    const s_unsplit = try unsplit.verifyBothCores(gpa, tmp.dir, "stkof_u.txt");
    const s_split = try split.verifyBothCores(gpa, tmp.dir, "stkof_s.txt");
    try std.testing.expect(s_split[0].switches > 0 and s_split[0].enters > 0 and s_split[0].idles > 0);
    try std.testing.expect(s_split[0].equal_pos > 0);
    try std.testing.expectEqual(s_unsplit, s_split);
    try compareWireToWire(unsplit.wire.got.items, split.wire.got.items);
}

test "snapshot save, diverging mutation, and restore continuation match 1-by-1" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(state_dir);

    // 1. Reference session: Phase 1 (65_000, crosses round 0 + mid-stretch carry=15_000), snapshot, Phase 2 (55_000).
    var ref: Rig = .{};
    try ref.open(gpa, dual0, dual1, state_dir);
    defer ref.deinit();
    try ref.subscribeBoth();
    try ref.runSplit(.cpu0, &.{ 60_000, 5_000 });
    try std.testing.expect(ref.served.owner.grid().stretch.carry > 0);
    const pre0 = try ref.wire.forCore(gpa, .cpu0);
    defer gpa.free(pre0);
    const pre1 = try ref.wire.forCore(gpa, .cpu1);
    defer gpa.free(pre1);
    try std.testing.expect(pre0.len > 0 and pre1.len > 0);
    try accepted(try ref.wire.call(proto.StatePath, .snapshot, .{ .path = "mid.ra8snap" }));
    try ref.runBudget(.cpu0, 55_000);
    _ = try ref.verifyBothCores(gpa, tmp.dir, "ref_snap.txt");

    // 2. Fresh session restored from mid.ra8snap, continued with split budgets summing to 55_000.
    var fresh: Rig = .{};
    try fresh.open(gpa, dual0, dual1, state_dir);
    defer fresh.deinit();
    try accepted(try fresh.wire.call(proto.StatePath, .restore, .{ .path = "mid.ra8snap" }));
    try fresh.subscribeBoth();
    try fresh.runSplit(.cpu0, &.{ 5_000, 30_000, 19_999, 1 });
    _ = try fresh.verifyBothCores(gpa, tmp.dir, "fresh_snap.txt");

    // 3. In-place session: advance + mutate guest SRAM past snapshot, restore, then trace Phase 2.
    var inplace: Rig = .{};
    try inplace.open(gpa, dual0, dual1, state_dir);
    defer inplace.deinit();
    try inplace.runSplit(.cpu0, &.{ 60_000, 5_000 });
    try accepted(try inplace.wire.call(proto.StatePath, .snapshot, .{ .path = "div.ra8snap" }));
    try inplace.runBudget(.cpu0, 29_999);
    try accepted(try inplace.wire.call(proto.WriteMemory, .write_memory, .{ .core = .cpu0, .address = 0x2200_0100, .bytes = &.{ 0x77, 0, 0, 0 } }));
    try accepted(try inplace.wire.call(proto.StatePath, .restore, .{ .path = "div.ra8snap" }));
    try inplace.subscribeBoth();
    try inplace.runBudget(.cpu0, 55_000);
    _ = try inplace.verifyBothCores(gpa, tmp.dir, "inplace_snap.txt");

    const ref0 = try ref.wire.forCore(gpa, .cpu0);
    defer gpa.free(ref0);
    const ref1 = try ref.wire.forCore(gpa, .cpu1);
    defer gpa.free(ref1);
    const fresh0 = try fresh.wire.forCore(gpa, .cpu0);
    defer gpa.free(fresh0);
    const fresh1 = try fresh.wire.forCore(gpa, .cpu1);
    defer gpa.free(fresh1);
    const in0 = try inplace.wire.forCore(gpa, .cpu0);
    defer gpa.free(in0);
    const in1 = try inplace.wire.forCore(gpa, .cpu1);
    defer gpa.free(in1);
    try std.testing.expect(fresh0.len > 0 and fresh1.len > 0);

    try compareWireToWire(ref0[pre0.len..], fresh0);
    try compareWireToWire(ref1[pre1.len..], fresh1);
    try compareWireToWire(ref0[pre0.len..], in0);
    try compareWireToWire(ref1[pre1.len..], in1);
}

test "concurrent independent served sessions interleave runs without trace cross-talk" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var a: Rig = .{};
    try a.open(gpa, dual0, dual1, null);
    defer a.deinit();
    try a.subscribeBoth();

    var b: Rig = .{};
    try b.open(gpa, two_threads, null, null);
    defer b.deinit();
    try accepted(try b.wire.call(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .trace }));

    try a.runBudget(.cpu0, 25_000);
    try b.runBudget(.cpu0, 2_300);
    try a.runBudget(.cpu1, 35_000);
    try b.runBudget(.cpu0, 4_700);
    try a.runBudget(.cpu0, 60_000);
    try b.runBudget(.cpu0, 13_000);

    const sa = try a.verifyBothCores(gpa, tmp.dir, "ind_a.txt");
    try std.testing.expect(sa[0].switches > 0 and sa[1].switches > 0);

    const b_wire0 = try b.wire.forCore(gpa, .cpu0);
    defer gpa.free(b_wire0);
    const b_wire1 = try b.wire.forCore(gpa, .cpu1);
    defer gpa.free(b_wire1);
    const b_file0 = try b.recordedCore(gpa, tmp.dir, "ind_b.txt", 0);
    defer gpa.free(b_file0);
    const sb = try compareSequence(b_wire0, b_file0, .cpu0);
    try std.testing.expect(sb.switches > 0);
    try std.testing.expectEqual(@as(usize, 0), b_wire1.len);
}

test "negative controls reject wrong kind, wrong timestamp, and swapped equal-position order" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var rig: Rig = .{};
    try rig.open(gpa, dual0, dual1, null);
    defer rig.deinit();
    try rig.subscribeBoth();
    try rig.runBudget(.cpu0, 12_000);

    const wire0 = try rig.wire.forCore(gpa, .cpu0);
    defer gpa.free(wire0);
    const file0 = try rig.recordedCore(gpa, tmp.dir, "neg.txt", 0);
    defer gpa.free(file0);
    const base = try compareSequence(wire0, file0, .cpu0);
    try std.testing.expect(base.equal_pos > 0);

    var bad_kind = try gpa.dupe(Got, wire0);
    defer gpa.free(bad_kind);
    bad_kind[0].kind = if (bad_kind[0].kind == .rtos_switch) .rtos_idle else .rtos_switch;
    try std.testing.expectError(error.KindMismatch, compareSequence(bad_kind, file0, .cpu0));

    var bad_time = try gpa.dupe(Got, wire0);
    defer gpa.free(bad_time);
    bad_time[bad_time.len - 1].virtual_ns += 1;
    try std.testing.expectError(error.TimeMismatch, compareSequence(bad_time, file0, .cpu0));

    var swapped_pair = false;
    for (1..wire0.len) |i| {
        if (wire0[i].virtual_ns == wire0[i - 1].virtual_ns and wire0[i].kind != wire0[i - 1].kind) {
            var swapped = try gpa.dupe(Got, wire0);
            defer gpa.free(swapped);
            std.mem.swap(Got, &swapped[i - 1], &swapped[i]);
            try std.testing.expectError(error.KindMismatch, compareSequence(swapped, file0, .cpu0));
            try std.testing.expectError(error.KindMismatch, compareWireToWire(swapped, wire0));
            swapped_pair = true;
            break;
        }
    }
    try std.testing.expect(swapped_pair);
}
