const std = @import("std");
const ra8 = @import("ra8");
const Harness = ra8.session.harness.Harness;
const Cpu1 = ra8.session.cpu1.bringup.Cpu1;
const map = ra8.chip.core.memmap;
const ns = ra8.chip.core.systick_bank.non_secure_words;
const Cut = ra8.chip.core.cpu.cpu.systick_cut.Cut;
const Pending = ra8.chip.core.cpu.cpu.systick_cut.Pending;
const State = ra8.chip.core.scheduler.State;
const Clock = ra8.session.run.loop.Clock;
const file = ra8.snapshot.file;
const alloc = std.testing.allocator;
const at = map.sram_base + 0x6000;

fn open() !Harness {
    return ra8.session.harness.open(alloc, std.testing.io, .{
        .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf",
        .history_frames = 2,
    });
}

fn setup(h: *Harness, stm: bool) !void {
    h.state.edge.idle_skip = false;
    try h.guest().write(at, if (stm) &.{ 0x00, 0xbf, 0x00, 0xbf, 0x0e, 0xc0, 0xfe, 0xe7 } else &.{ 0x00, 0xbf, 0x00, 0xbf, 0x01, 0x60, 0xfe, 0xe7 });
    const cpu = h.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = if (stm) map.syst.csr else map.syst.rvr;
    cpu.regs.low[1] = if (stm) 7 else 4;
    cpu.regs.low[2] = 4;
    cpu.regs.low[3] = 0;
    cpu.regs.primask = 1;
    cpu.banked.current = .secure;
    cpu.waiting = null;
    h.state.memory.security = &cpu.banked;
    try h.guest().writeWord(map.syst.csr, if (stm) 5 else 7);
    try h.guest().writeWord(map.syst.rvr, 9);
    try h.guest().writeWord(map.syst.cvr, if (stm) 3 else 8);
    try h.guest().writeWord(ns.csr, 0);
    try h.guest().writeWord(ns.rvr, 0);
    try h.guest().writeWord(ns.cvr, 0);
    try h.guest().writeWord(0xe000_1000, 1);
    try h.guest().writeWord(0xe000_edfc, 1 << 24);
}

fn capture(h: *Harness) !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(alloc);
    errdefer out.deinit();
    try h.state.files.writeTo(&out.writer);
    return out;
}

fn continueRun(h: *Harness) !void {
    try h.session().setRunBudget(.cpu0, 1);
    const ended = try h.session().run(.cpu0, .cont);
    std.debug.print("CONTINUE ended={any} pc=0x{x} saved={any}\n", .{ ended, h.primaryCpu().regs.pc, h.state.edge.saved });
    try std.testing.expect(ended == .count);
}

fn stop(h: *Harness, stm: bool) !void {
    try setup(h, stm);
    _ = try h.session().setWatchpoint(.cpu0, .{ .first = map.syst.rvr, .last = map.syst.rvr + 3, .kind = .write });
    const before = h.primaryCpu().slots;
    try h.session().setRunBudget(.cpu0, 3);
    const ended = try h.session().run(.cpu0, .cont);
    std.debug.print("STOP stm={} ended={any} pc=0x{x} r0=0x{x} slots={d} csr={d} rvr={d} cvr={d} saved={any} board={d} dwt={d}\n", .{
        stm,                                  ended,                                h.primaryCpu().regs.pc,               h.primaryCpu().regs.low[0], h.primaryCpu().slots - before,
        try h.guest().readWord(map.syst.csr), try h.guest().readWord(map.syst.rvr), try h.guest().readWord(map.syst.cvr), h.state.edge.saved,         h.board().time.base.retired,
        try h.guest().readWord(0xe000_1004),
    });
    if (ended != .stop or ended.stop != .watchpoint or h.primaryCpu().regs.pc != at + 6 or h.primaryCpu().slots - before != 3) return error.NotReached;
    if (stm and h.primaryCpu().regs.low[0] != map.syst.csr + 12) return error.NotReached;
    const saved = h.state.edge.saved;
    if (!saved.cut or saved.cut_pending.bank != .secure or saved.cut_pending.old_reload != 9 or saved.cut_pending.old_control != @as(u8, if (stm) 1 else 3) or saved.stretch.carry != 3) return error.NotReached;
    try std.testing.expectEqual(@as(u64, 0), h.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 0), try h.guest().readWord(0xe000_1004));
    try std.testing.expectEqual(@as(u64, 1), h.state.edge.timebase.rearms);
    try std.testing.expectEqual(@as(u64, 0), h.state.edge.ns_timebase.rearms);
}

pub fn atomicControl() !void {
    var second: Cpu1 = .{};
    var h = try open();
    defer h.deinit();
    try second.open(alloc, std.testing.io, &h, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(alloc);
    try stop(&h, false);
    var before = try capture(&h);
    defer before.deinit();
    const section = (try file.Reader.find(before.written(), .grid)).?;
    try std.testing.expectEqual(@as(usize, 63), section.payload.len);
    try std.testing.expectEqual(@as(u8, 0), section.payload[52]);
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, section.payload[53..57], .little));
    try std.testing.expectEqual(@as(u8, 3), section.payload[57]);
    const offset = @intFromPtr(section.payload.ptr) - @intFromPtr(before.written().ptr) + 57;
    const bad = try alloc.dupe(u8, before.written());
    defer alloc.free(bad);
    bad[offset] = 2;
    var differences: usize = 0;
    for (bad, before.written()) |a, b| {
        if (a != b) differences += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), differences);
    try continueRun(&h);
    const reference_cvr = try h.guest().readWord(map.syst.cvr);
    var reference = try capture(&h);
    defer reference.deinit();
    try h.state.files.readFrom(before.written());
    var restored = try capture(&h);
    defer restored.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), restored.written());
    var refusal: ?anyerror = null;
    h.state.files.readFrom(bad) catch |err| {
        refusal = err;
    };
    var after = try capture(&h);
    defer after.deinit();
    const unchanged = std.mem.eql(u8, before.written(), after.written());
    std.debug.print("F1 REACHED grid_len={d} byte57=3->2 changed_bytes={d} error={any} recapture_unchanged={} pending={any}\n", .{ section.payload.len, differences, refusal, unchanged, h.state.edge.saved.cut_pending });
    try continueRun(&h);
    var future = try capture(&h);
    defer future.deinit();
    const future_equal = std.mem.eql(u8, reference.written(), future.written());
    const actual_cvr = try h.guest().readWord(map.syst.cvr);
    std.debug.print("F1 FUTURE equal={} reference_cvr={d} actual_cvr={d} board={d} dwt={d} ticks={d} pends={d}\n", .{ future_equal, reference_cvr, actual_cvr, h.board().time.base.retired, try h.guest().readWord(0xe000_1004), h.state.edge.timebase.ticks, h.state.edge.timebase.pends });
    try std.testing.expectEqual(@as(u32, 5), reference_cvr);
    const bad_value = if (refusal) |err| err == error.BadValue else false;
    if (!bad_value or !unchanged or !future_equal) return error.F1AtomicRefusalFailed;
}

// Sequential scratch tests intercept the close without changing its context.
var original_close: *const fn (*anyopaque, u32) anyerror!void = undefined;
var close_saved: *State = undefined;
var close_harness: *Harness = undefined;
var close_count: u32 = 0;
var seen_pending: Pending = .{};
fn inspectClose(ctx: *anyopaque, count: u32) !void {
    close_count += 1;
    seen_pending = close_saved.cut_pending;
    const h = close_harness;
    std.debug.print("F2 PRE_CLOSE cycles={d} cut={} pending={any} carry={d} phase={s} cvr={d} csr=0x{x} ticks={d} pends={d} board={d} dwt={d}\n", .{
        count,                                close_saved.cut,                      seen_pending,                close_saved.stretch.carry,   @tagName(close_saved.at.phase),
        try h.guest().readWord(map.syst.cvr), try h.guest().readWord(map.syst.csr), h.state.edge.timebase.ticks, h.state.edge.timebase.pends, h.board().time.base.retired,
        try h.guest().readWord(0xe000_1004),
    });
    try original_close(ctx, count);
}

fn expectOldWrap(h: *Harness, initial_current: u32) !void {
    // Product oracle, not a hardware timing claim: charge old interval first;
    // then retain the instruction's final CVR0 write. Existing plain-RAM CVR
    // store has no COUNTFLAG-clear hook; keep the old interval's computed flag.
    const prior = ra8.chip.periph.clocks.wrap(initial_current, 9, 3);
    const cvr = try h.guest().readWord(map.syst.cvr);
    const csr = try h.guest().readWord(map.syst.csr);
    std.debug.print("F2 ORACLE old wrap={any} final_CVR_write=0 old_TICKINT=0 expected_ticks=old_periods pends=0 cvr=0 ACTUAL cvr={d} csr=0x{x} ticks={d} pends={d}\n", .{ prior, cvr, csr, h.state.edge.timebase.ticks, h.state.edge.timebase.pends });
    try std.testing.expectEqual(prior.periods, h.state.edge.timebase.ticks);
    try std.testing.expectEqual(@as(u64, 0), h.state.edge.timebase.pends);
    try std.testing.expectEqual(@as(u32, 0), cvr);
    try std.testing.expectEqual(@as(u32, if (prior.periods != 0) 0x10007 else 7), csr);
    try std.testing.expectEqual(@as(u32, 0), (try h.guest().readWord(map.scb.icsr)) & (1 << 26));
}

pub fn stmCase(plain: bool, initial_current: u32) !void {
    var second: Cpu1 = .{};
    var h = try open();
    defer h.deinit();
    try second.open(alloc, std.testing.io, &h, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(alloc);
    try setup(&h, true);
    try h.guest().writeWord(map.syst.cvr, initial_current);
    const cpu = h.primaryCpu();
    const before0 = cpu.slots;
    const before1 = second.cpu().slots;
    close_count = 0;
    seen_pending = .{};
    close_harness = &h;
    var clock: Clock = .{ .io = std.testing.io, .memory = h.guest(), .board = h.board(), .timebase = &h.state.edge.timebase, .cpu1 = h.state.files.pair };
    var cut: Cut = .{ .clocks = .{ clock.timebase, &clock.ns_timebase } };
    var reached = false;
    if (plain) {
        h.state.memory.scs.cut = &cut;
        cpu.cut = &cut;
        var edge = clock.boundary();
        original_close = edge.closeFn;
        close_saved = &clock.saved;
        edge.closeFn = inspectClose;
        var owed: ra8.chip.core.cpu.boot.Owed = .{ .hold = true };
        const ended = try ra8.chip.core.cpu.boot.stretches(cpu, 3, edge, null, &owed, null);
        std.debug.print("F2 PLAIN ended={any} saved={any} latch={} pending={any}\n", .{ ended, clock.saved, cut.fired, cut.pending });
        reached = ended == .count;
    } else {
        const edge = &h.session().live.boundary.?;
        original_close = edge.tickFn;
        close_saved = &h.state.edge.saved;
        edge.tickFn = inspectClose;
        try h.session().setRunBudget(.cpu0, 3);
        const ended = try h.session().run(.cpu0, .cont);
        std.debug.print("F2 SESSION ended={any} saved={any} latch={} pending={any}\n", .{ ended, h.state.edge.saved, h.state.edge.cut.fired, h.state.edge.cut.pending });
        reached = ended == .count;
    }
    std.debug.print("F2 REACH plain={} ended_count={} pc=0x{x} r0=0x{x} slots={d} peer_slots={d} board={d} dwt={d} closes={d} rvr={d} cvr={d} csr=0x{x} ticks={d} pends={d}\n", .{
        plain,                               reached,     cpu.regs.pc,                          cpu.regs.low[0],                      cpu.slots - before0,                  second.cpu().slots - before1, h.board().time.base.retired,
        try h.guest().readWord(0xe000_1004), close_count, try h.guest().readWord(map.syst.rvr), try h.guest().readWord(map.syst.cvr), try h.guest().readWord(map.syst.csr), h.state.edge.timebase.ticks,  h.state.edge.timebase.pends,
    });
    if (!reached or cpu.regs.pc != at + 6 or cpu.regs.low[0] != map.syst.csr + 12 or cpu.slots - before0 != 3 or try h.guest().readWord(map.syst.rvr) != 4) return error.NotReached;
    try std.testing.expectEqual(@as(u64, 3), h.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 3), try h.guest().readWord(0xe000_1004));
    try std.testing.expectEqual(before1, second.cpu().slots);
    try std.testing.expectEqual(@as(u32, 1), close_count);
    try std.testing.expectEqual(@as(u32, 9), seen_pending.old_reload);
    try std.testing.expectEqual(@as(u8, 1), seen_pending.old_control);
    try expectOldWrap(&h, initial_current);
}

pub fn stoppedStm() !void {
    var second: Cpu1 = .{};
    var h = try open();
    defer h.deinit();
    try second.open(alloc, std.testing.io, &h, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(alloc);
    const before1 = second.cpu().slots;
    try stop(&h, true);
    try std.testing.expectEqual(@as(u32, 7), try h.guest().readWord(map.syst.csr));
    var before = try capture(&h);
    defer before.deinit();
    try continueRun(&h);
    var reference = try capture(&h);
    defer reference.deinit();
    const reference_ticks = h.state.edge.timebase.ticks;
    const reference_pends = h.state.edge.timebase.pends;
    try h.state.files.readFrom(before.written());
    var restored = try capture(&h);
    defer restored.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), restored.written());
    try std.testing.expectEqual(@as(u8, 1), h.state.edge.saved.cut_pending.old_control);
    try std.testing.expectEqual(@as(u32, 7), try h.guest().readWord(map.syst.csr));
    try continueRun(&h);
    var future = try capture(&h);
    defer future.deinit();
    const equal = std.mem.eql(u8, reference.written(), future.written());
    std.debug.print("STM SNAPSHOT REACHED equal={} old_control=1 final_control=3 reference_ticks={d} reference_pends={d} actual_ticks={d} actual_pends={d} board={d} dwt={d} cpu1_delta={d}\n", .{ equal, reference_ticks, reference_pends, h.state.edge.timebase.ticks, h.state.edge.timebase.pends, h.board().time.base.retired, try h.guest().readWord(0xe000_1004), second.cpu().slots - before1 });
    try std.testing.expect(equal);
    try std.testing.expectEqual(before1, second.cpu().slots);
    try std.testing.expectEqual(@as(u64, 3), h.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 3), try h.guest().readWord(0xe000_1004));
    try expectOldWrap(&h, 3);
}

pub fn canonical() !void {
    var second: Cpu1 = .{};
    var h = try open();
    defer h.deinit();
    try second.open(alloc, std.testing.io, &h, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(alloc);
    try stop(&h, true);
    var before = try capture(&h);
    defer before.deinit();
    const section = (try file.Reader.find(before.written(), .grid)).?;
    try std.testing.expectEqual(@as(usize, 63), section.payload.len);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, section.payload[58..62], .little));
    try std.testing.expectEqual(@as(u8, 1), section.payload[62]);
    const fixture = @import("../board/state_fixture.zig");
    for (0..5) |variant| {
        var payload: [63]u8 = undefined;
        @memcpy(&payload, section.payload);
        switch (variant) {
            0 => std.mem.writeInt(u32, payload[58..62], 1 << 24, .little),
            1 => payload[62] = 2, // Noncanonical boolean.
            2 => payload[62] = 0, // Unwritten current must be zero.
            3 => {
                payload[51] = 0; // Non-cut state cannot retain a CVR write.
                @memset(payload[52..62], 0);
            },
            else => {}, // Missing the required write marker.
        }
        var bad = try fixture.replacement(before.written(), .grid, payload[0..if (variant == 4) 62 else 63]);
        defer bad.deinit();
        try std.testing.expectError(if (variant == 4) error.Truncated else error.BadValue, h.state.files.readFrom(bad.written()));
        var after = try capture(&h);
        defer after.deinit();
        try std.testing.expectEqualSlices(u8, before.written(), after.written());
        std.debug.print("TAIL_SCHEMA variant={d} atomic_refusal=true\n", .{variant});
    }
    const old = try alloc.dupe(u8, before.written());
    defer alloc.free(old);
    std.mem.writeInt(u32, old[file.magic.len..][0..4], 11, .little);
    try std.testing.expectError(error.BadVersion, h.state.files.readFrom(old));
    var after = try capture(&h);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
    try continueRun(&h);
    try expectOldWrap(&h, 3);
}
