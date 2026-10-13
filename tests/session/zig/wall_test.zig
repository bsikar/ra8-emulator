//! Cut-clock closes through the Session and plain run adapters.
const std = @import("std");
const ra8 = @import("ra8");
const Harness = ra8.session.harness.Harness;
const Cpu1 = ra8.session.cpu1.bringup.Cpu1;
const map = ra8.chip.core.memmap;
const ns = ra8.chip.core.systick_bank.non_secure_words;
const tail = @import("wall_tail_fixture.zig");

test "cut tail F1 disabled control with nonzero old reload is atomic" {
    try tail.atomicControl();
}

test "cut tail F2 Session three-store STM retains old wrap" {
    try tail.stmCase(false, 3);
}

test "cut tail F2 plain three-store STM retains old wrap" {
    try tail.stmCase(true, 3);
}

test "cut tail stopped STM distinct controls survive snapshot continuation" {
    try tail.stoppedStm();
}

test "cut tail final CVR store wins over a nonzero old countdown" {
    try tail.stmCase(false, 8);
    try tail.stmCase(true, 8);
}

test "cut tail pending counter schema refuses malformed state atomically" {
    try tail.canonical();
}

const Target = enum { secure, non_secure_alias, non_secure_phase };

fn check(target: Target, old_start: u32, old_end: u32, wrapped: bool) !void {
    var second: Cpu1 = .{};
    var live: Harness = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf",
        .history_frames = 2,
    });
    defer live.deinit();
    try second.open(std.testing.allocator, std.testing.io, &live, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(std.testing.allocator);
    live.state.edge.idle_skip = false;

    const at = if (target == .non_secure_phase) map.ns_sram_base + 0x6000 else map.sram_base + 0x6000;
    try live.guest().write(at, &.{ 0x00, 0xbf, 0x00, 0xbf, 0x01, 0x60, 0xfe, 0xe7 });
    const cpu = live.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = if (target == .non_secure_alias) ns.csr else map.syst.csr;
    cpu.regs.low[1] = 7;
    cpu.regs.primask = 1;
    cpu.banked.current = if (target == .non_secure_phase) .non_secure else .secure;
    cpu.waiting = null;
    live.state.memory.security = &cpu.banked;

    const newly = if (target == .secure) ra8.chip.periph.clocks.Words{} else ns;
    const older = if (target == .secure) ns else ra8.chip.periph.clocks.Words{};
    try live.guest().writeWord(newly.csr, 0);
    try live.guest().writeWord(newly.rvr, 4);
    try live.guest().writeWord(newly.cvr, 0);
    try live.guest().writeWord(older.csr, 7);
    try live.guest().writeWord(older.rvr, 9);
    try live.guest().writeWord(older.cvr, old_start);
    try live.guest().writeWord(0xe000_1000, 1);
    try live.guest().writeWord(0xe000_edfc, 1 << 24);

    const before0 = cpu.slots;
    const before1 = second.cpu().slots;
    const pre_new = try live.guest().readWord(newly.cvr);
    const pre_old = try live.guest().readWord(older.cvr);
    try live.session().setRunBudget(.cpu0, 3);
    const ended = try live.session().run(.cpu0, .cont);
    const new_cvr = try live.guest().readWord(newly.cvr);
    const old_cvr = try live.guest().readWord(older.cvr);
    const dwt = try live.guest().readWord(0xe000_1004);
    std.debug.print("CHECK=opposite-bank target={s} phase={s} address=0x{x} pc=0x{x} csr_new={d} pre_new={d} pre_old={d} ended={any} cpu0_delta={d} cpu1_delta={d} board={d} dwt={d} new_cvr={d} old_cvr={d} new_ticks={d} old_ticks={d} round={d} rearms_secure={d} rearms_ns={d}\n", .{
        @tagName(target),                   @tagName(cpu.banked.current),   cpu.regs.low[0], cpu.regs.pc, try live.guest().readWord(newly.csr), pre_new,                                                                                      pre_old,                                                                                      ended,                      cpu.slots - before0,
        second.cpu().slots - before1,       live.board().time.base.retired, dwt,             new_cvr,     old_cvr,                              if (target == .secure) live.state.edge.timebase.ticks else live.state.edge.ns_timebase.ticks, if (target == .secure) live.state.edge.ns_timebase.ticks else live.state.edge.timebase.ticks, live.state.edge.saved.at.r, live.state.edge.timebase.rearms,
        live.state.edge.ns_timebase.rearms,
    });
    try std.testing.expectEqual(@as(u32, 0), pre_new);
    try std.testing.expectEqual(old_start, pre_old);
    try std.testing.expect(ended == .count);
    try std.testing.expectEqual(before0 + 3, cpu.slots);
    try std.testing.expectEqual(before1, second.cpu().slots);
    try std.testing.expectEqual(@as(u64, 3), live.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 3), dwt);
    try std.testing.expectEqual(@as(u32, 0), new_cvr);
    try std.testing.expectEqual(old_end, old_cvr);
    const new_clock = if (target == .secure) live.state.edge.timebase else live.state.edge.ns_timebase;
    try std.testing.expectEqual(@as(u64, 0), new_clock.ticks);
    try std.testing.expectEqual(@as(u64, 0), new_clock.pends);
    try std.testing.expectEqual(@as(u32, 0), (try live.guest().readWord(newly.csr)) & (1 << 16));
    try std.testing.expectEqual(@as(u32, 0), (try live.guest().readWord(newly.icsr)) & (1 << 26));
    const old_clock = if (target == .secure) live.state.edge.ns_timebase else live.state.edge.timebase;
    try std.testing.expectEqual(@as(u64, @intFromBool(wrapped)), old_clock.ticks);
    try std.testing.expectEqual(@as(u64, @intFromBool(wrapped)), old_clock.pends);
    try std.testing.expectEqual(@as(u32, if (wrapped) 1 << 16 else 0), (try live.guest().readWord(older.csr)) & (1 << 16));
    try std.testing.expectEqual(@as(u32, if (wrapped) 1 << 26 else 0), (try live.guest().readWord(older.icsr)) & (1 << 26));
}

test "grid G6 secure start leaves the old nonsecure timer running" {
    try check(.secure, 8, 5, false);
}

test "grid G6 secure alias start leaves the old secure timer running" {
    try check(.non_secure_alias, 8, 5, false);
}

test "grid G6 nonsecure execution reaches a cut and leaves the old secure timer running" {
    try check(.non_secure_phase, 8, 5, false);
}

test "grid G6 untouched nonsecure timer wraps and pends on a secure cut" {
    try check(.secure, 3, 0, true);
}

test "grid G6 nonsecure execution preserves a secure wrap and pend" {
    try check(.non_secure_phase, 3, 0, true);
}

fn rearm(plain: bool, old_start: u32, old_end: u32, wrapped: bool) !void {
    var second: Cpu1 = .{};
    var live: Harness = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf",
        .history_frames = 2,
    });
    defer live.deinit();
    try second.open(std.testing.allocator, std.testing.io, &live, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(std.testing.allocator);
    live.state.edge.idle_skip = false;
    const at = map.sram_base + 0x6000;
    try live.guest().write(at, &.{ 0x00, 0xbf, 0x00, 0xbf, 0x01, 0x60, 0xfe, 0xe7 });
    const cpu = live.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = map.syst.rvr;
    cpu.regs.low[1] = 4;
    cpu.regs.primask = 1;
    cpu.banked.current = .secure;
    cpu.waiting = null;
    live.state.memory.security = &cpu.banked;
    try live.guest().writeWord(map.syst.csr, 7);
    try live.guest().writeWord(map.syst.rvr, 9);
    try live.guest().writeWord(map.syst.cvr, old_start);
    try live.guest().writeWord(0xe000_1000, 1);
    try live.guest().writeWord(0xe000_edfc, 1 << 24);
    const before1 = second.cpu().slots;

    if (plain) {
        const Clock = ra8.session.run.loop.Clock;
        var clock: Clock = .{ .io = std.testing.io, .memory = live.guest(), .board = live.board(), .timebase = &live.state.edge.timebase, .cpu1 = live.state.files.pair };
        var cut: ra8.chip.core.cpu.cpu.systick_cut.Cut = .{ .clocks = .{ clock.timebase, &clock.ns_timebase } };
        live.state.memory.scs.cut = &cut;
        cpu.cut = &cut;
        var owed: ra8.chip.core.cpu.boot.Owed = .{ .hold = true };
        const ended = try ra8.chip.core.cpu.boot.stretches(cpu, 3, clock.boundary(), null, &owed, null);
        std.debug.print("CHECK=rearm plain ended={any} pc=0x{x} rvr={d} cvr={d} board={d} dwt={d} cpu1_delta={d} cut_round={d} rearms={d}\n", .{
            ended,                           cpu.regs.pc,                            try live.guest().readWord(map.syst.rvr), try live.guest().readWord(map.syst.cvr),
            live.board().time.base.retired,  try live.guest().readWord(0xe000_1004), second.cpu().slots - before1,            clock.saved.at.r,
            live.state.edge.timebase.rearms,
        });
        try std.testing.expect(ended == .count);
    } else {
        try live.session().setRunBudget(.cpu0, 3);
        const ended = try live.session().run(.cpu0, .cont);
        std.debug.print("CHECK=rearm session ended={any} pc=0x{x} rvr={d} cvr={d} board={d} dwt={d} cpu1_delta={d} cut_round={d} rearms={d}\n", .{
            ended,                           cpu.regs.pc,                            try live.guest().readWord(map.syst.rvr), try live.guest().readWord(map.syst.cvr),
            live.board().time.base.retired,  try live.guest().readWord(0xe000_1004), second.cpu().slots - before1,            live.state.edge.saved.at.r,
            live.state.edge.timebase.rearms,
        });
        try std.testing.expect(ended == .count);
    }
    try std.testing.expectEqual(@as(u32, 4), try live.guest().readWord(map.syst.rvr));
    try std.testing.expectEqual(@as(u64, 3), live.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 3), try live.guest().readWord(0xe000_1004));
    try std.testing.expectEqual(before1, second.cpu().slots);
    try std.testing.expectEqual(old_end, try live.guest().readWord(map.syst.cvr));
    try std.testing.expectEqual(@as(u64, @intFromBool(wrapped)), live.state.edge.timebase.ticks);
    try std.testing.expectEqual(@as(u64, @intFromBool(wrapped)), live.state.edge.timebase.pends);
    try std.testing.expectEqual(@as(u32, if (wrapped) 1 << 16 else 0), (try live.guest().readWord(map.syst.csr)) & (1 << 16));
    try std.testing.expectEqual(@as(u32, if (wrapped) 1 << 26 else 0), (try live.guest().readWord(map.scb.icsr)) & (1 << 26));
}

test "grid G6 Session old running target retains its pre-store reload" {
    try rearm(false, 8, 5, false);
}

test "grid G6 plain old running target retains its pre-store reload" {
    try rearm(true, 8, 5, false);
}

test "grid G6 Session old target wraps and pends during a reload cut" {
    try rearm(false, 3, 0, true);
}

test "grid G6 plain old target wraps and pends during a reload cut" {
    try rearm(true, 3, 0, true);
}

fn multiStore(plain: bool, diagnostic: bool) !void {
    var second: Cpu1 = .{};
    var live = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf",
        .history_frames = 2,
    });
    defer live.deinit();
    try second.open(std.testing.allocator, std.testing.io, &live, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(std.testing.allocator);
    live.state.edge.idle_skip = false;
    const at = map.sram_base + 0x6000;
    try live.guest().write(at, &.{ 0x00, 0xbf, 0x00, 0xbf, 0x06, 0xc0, 0xfe, 0xe7 });
    const cpu = live.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = map.syst.csr;
    cpu.regs.low[1] = 7;
    cpu.regs.low[2] = 4;
    cpu.regs.primask = 1;
    cpu.waiting = null;
    live.state.memory.security = &cpu.banked;
    try live.guest().writeWord(map.syst.csr, if (diagnostic) 5 else 0);
    try live.guest().writeWord(map.syst.rvr, 9);
    try live.guest().writeWord(map.syst.cvr, if (diagnostic) 3 else 0);
    try live.guest().writeWord(ns.csr, 0);
    try live.guest().writeWord(ns.rvr, 0);
    try live.guest().writeWord(ns.cvr, 0);
    try live.guest().writeWord(0xe000_1000, 1);
    try live.guest().writeWord(0xe000_edfc, 1 << 24);
    const before0 = cpu.slots;
    const before1 = second.cpu().slots;
    var clock: ra8.session.run.loop.Clock = .{ .io = std.testing.io, .memory = live.guest(), .board = live.board(), .timebase = &live.state.edge.timebase, .cpu1 = live.state.files.pair };
    var cut: ra8.chip.core.cpu.cpu.systick_cut.Cut = .{ .clocks = .{ clock.timebase, &clock.ns_timebase } };
    if (plain) {
        live.state.memory.scs.cut = &cut;
        cpu.cut = &cut;
        var owed: ra8.chip.core.cpu.boot.Owed = .{ .hold = true };
        const ended = try ra8.chip.core.cpu.boot.stretches(cpu, 3, clock.boundary(), null, &owed, null);
        try std.testing.expect(ended == .count);
    } else {
        try live.session().setRunBudget(.cpu0, 3);
        const ended = try live.session().run(.cpu0, .cont);
        try std.testing.expect(ended == .count);
    }
    const cvr = try live.guest().readWord(map.syst.cvr);
    const csr = try live.guest().readWord(map.syst.csr);
    const ticks = live.state.edge.timebase.ticks;
    const pends = live.state.edge.timebase.pends;
    std.debug.print("CHECK=G6 STM plain={} diagnostic={} pc=0x{x} r0=0x{x} cvr={d} csr=0x{x} ticks={d} pends={d} rearms={d} board={d} dwt={d}\n", .{
        plain,                          diagnostic,                             cpu.regs.pc, cpu.regs.low[0], cvr, csr, ticks, pends, live.state.edge.timebase.rearms,
        live.board().time.base.retired, try live.guest().readWord(0xe000_1004),
    });
    try std.testing.expectEqual(at + 6, cpu.regs.pc);
    try std.testing.expectEqual(map.syst.csr + 8, cpu.regs.low[0]);
    try std.testing.expectEqual(before0 + 3, cpu.slots);
    try std.testing.expectEqual(before1, second.cpu().slots);
    try std.testing.expectEqual(@as(u32, 4), try live.guest().readWord(map.syst.rvr));
    try std.testing.expectEqual(@as(u64, 3), live.board().time.base.retired);
    try std.testing.expectEqual(@as(u32, 3), try live.guest().readWord(0xe000_1004));
    try std.testing.expectEqual(@as(u32, 0), cvr);
    try std.testing.expectEqual(@as(u64, @intFromBool(diagnostic)), ticks);
    try std.testing.expectEqual(@as(u64, 0), pends);
    try std.testing.expectEqual(@as(u32, if (diagnostic) 1 << 16 else 0), csr & (1 << 16));
    try std.testing.expectEqual(@as(u32, 0), (try live.guest().readWord(map.scb.icsr)) & (1 << 26));
    try std.testing.expectEqual(@as(u64, if (diagnostic) 1 else 2), live.state.edge.timebase.rearms);
}

test "grid G6 Session multi-store start preserves pre-arm zero" {
    try multiStore(false, false);
}

test "grid G6 plain multi-store start preserves pre-arm zero" {
    try multiStore(true, false);
}

test "grid G6 Session multi-store retains prior TICKINT" {
    try multiStore(false, true);
}

test "grid G6 stopped store restores its pending close without double charge" {
    var second: Cpu1 = .{};
    var live = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf",
        .history_frames = 2,
    });
    defer live.deinit();
    try second.open(std.testing.allocator, std.testing.io, &live, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(std.testing.allocator);
    live.state.edge.idle_skip = false;
    const at = map.sram_base + 0x6000;
    try live.guest().write(at, &.{ 0x00, 0xbf, 0x00, 0xbf, 0x01, 0x60, 0xfe, 0xe7 });
    const cpu = live.primaryCpu();
    cpu.regs.pc = at;
    cpu.regs.low[0] = map.syst.rvr;
    cpu.regs.low[1] = 4;
    cpu.regs.primask = 1;
    cpu.waiting = null;
    try live.guest().writeWord(map.syst.csr, 7);
    try live.guest().writeWord(map.syst.rvr, 9);
    try live.guest().writeWord(map.syst.cvr, 8);
    try live.guest().writeWord(0xe000_1000, 1);
    try live.guest().writeWord(0xe000_edfc, 1 << 24);
    _ = try live.session().setWatchpoint(.cpu0, .{ .first = map.syst.rvr, .last = map.syst.rvr + 3, .kind = .write });
    try live.session().setRunBudget(.cpu0, 3);
    const ended = try live.session().run(.cpu0, .cont);
    std.debug.print("CHECK=G6 stop ended={any} cut={} phase={s} carry={d} board={d} watch={any} unit={any} mode={s}\n", .{
        ended,                            live.state.edge.saved.cut,       @tagName(live.state.edge.saved.at.phase), live.state.edge.saved.stretch.carry, live.board().time.base.retired,
        live.state.machine.watch_pending, live.state.machine.unit_pending, @tagName(live.state.machine.mode),
    });
    try std.testing.expect(ended == .stop and ended.stop == .watchpoint);
    try std.testing.expect(live.state.edge.saved.cut);
    try std.testing.expectEqual(ra8.chip.core.cpu.cpu.systick_cut.Pending.Bank.secure, live.state.edge.saved.cut_pending.bank);
    try std.testing.expectEqual(@as(u32, 9), live.state.edge.saved.cut_pending.old_reload);
    try std.testing.expectEqual(@as(u64, 0), live.board().time.base.retired);
    var before = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer before.deinit();
    try live.state.files.writeTo(&before.writer);
    try live.session().setRunBudget(.cpu0, 1);
    _ = try live.session().run(.cpu0, .cont);
    var reference = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer reference.deinit();
    try live.state.files.writeTo(&reference.writer);
    const peer_slots = second.cpu().slots;
    try live.state.files.readFrom(before.written());
    try std.testing.expectEqual(@as(u32, 9), live.state.edge.saved.cut_pending.old_reload);
    try live.session().setRunBudget(.cpu0, 1);
    _ = try live.session().run(.cpu0, .cont);
    var restored = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer restored.deinit();
    try live.state.files.writeTo(&restored.writer);
    try std.testing.expectEqualSlices(u8, reference.written(), restored.written());
    try std.testing.expectEqual(peer_slots, second.cpu().slots);
    std.debug.print("CHECK=G6 pending restore old_reload=9 board={d} dwt={d} cvr={d}\n", .{
        live.board().time.base.retired, try live.guest().readWord(0xe000_1004), try live.guest().readWord(map.syst.cvr),
    });
}
