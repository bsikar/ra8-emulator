//! QTR-002 COMMON qualification tests: exhaustive negative controls NC-01..NC-07
//! across all 59 Cortex registers on both cores, all 12 SpaceId backing spaces,
//! TrustZone & cross-core aliases, lossless P6 PPM frames, scheduler/carry,
//! continuous ITM/UART streams, peripherals, attachments/faults, and real
//! dual-core IPC + ThreadX recording/snapshot continuation parity.
const std = @import("std");
const t = std.testing;
const ra8 = @import("ra8");
const oracle = @import("common_oracle.zig");
const fixture = @import("../board/state_fixture.zig");
const fakes = @import("../history_fakes.zig");

const Harness = ra8.session.harness.Harness;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Cortex = ra8.chip.core.cpu.cortex.Cortex;
const ZigCore = ra8.session.zig.core.ZigCore;
const Store = ra8.chip.core.cpu.memory.store.Store;
const memmap = ra8.chip.core.memmap;

const ipc_elf = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
const ipc1_elf = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf";
const threadx_elf = "tests/fixtures/threadx/threadx_stkof.elf";
const dfu_elf = "tests/fixtures/dfu/dfu_bootloader.elf";

fn same(a: oracle.Capture, b: oracle.Capture) !void {
    if (a.first(b)) |domain| {
        std.debug.print("COMMON mismatch in domain: {s}\n", .{domain});
        return error.GuestDivergence;
    }
}

fn changed(a: oracle.Capture, b: oracle.Capture, expected_domain: []const u8) !void {
    const actual = a.first(b) orelse return error.MissedDivergence;
    try t.expectEqualStrings(expected_domain, actual);
}

fn savedSnapshot(h: *Harness) !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(t.allocator);
    errdefer out.deinit();
    try h.state.files.writeTo(&out.writer);
    return out;
}

fn verifyAll59CortexAndHidden(cpu: *Cpu) !void {
    const base = oracle.core(cpu);
    const saved_cpu = cpu.*;
    const view: ZigCore = .{ .cpu = cpu };
    var tested_regs: usize = 0;

    inline for (std.meta.tags(Cortex)) |tag| {
        const cur = view.register(tag);
        const mask: u32 = switch (tag) {
            .sp, .msp, .psp, .msplim, .psplim => 0x8,
            .fpscr => 0x8000_0000,
            else => 0x1,
        };
        view.setRegister(tag, cur ^ mask);
        try t.expect(!std.meta.eql(base, oracle.core(cpu)));
        cpu.* = saved_cpu;
        try t.expectEqual(base, oracle.core(cpu));
        tested_regs += 1;
    }
    try t.expectEqual(@as(usize, 59), tested_regs);

    inline for (@typeInfo(@TypeOf(cpu.banked.other)).@"struct".field_names) |name| {
        @field(cpu.banked.other, name) ^= 8;
        try t.expect(!std.meta.eql(base, oracle.core(cpu)));
        cpu.* = saved_cpu;
    }
    cpu.fp.context.fpcar ^= 8;
    try t.expect(!std.meta.eql(base, oracle.core(cpu)));
    cpu.* = saved_cpu;

    inline for (.{ "retired", "slots", "sync_entries", "vtor", "secure_faults" }) |name| {
        @field(cpu, name) ^= 1;
        try t.expect(!std.meta.eql(base, oracle.core(cpu)));
        cpu.* = saved_cpu;
    }
    cpu.banked.current = if (saved_cpu.banked.current == .secure) .non_secure else .secure;
    try t.expect(!std.meta.eql(base, oracle.core(cpu)));
    cpu.* = saved_cpu;

    cpu.entering_non_secure = !saved_cpu.entering_non_secure;
    try t.expect(!std.meta.eql(base, oracle.core(cpu)));
    cpu.* = saved_cpu;

    cpu.event = !saved_cpu.event;
    try t.expect(!std.meta.eql(base, oracle.core(cpu)));
    cpu.* = saved_cpu;

    cpu.booted = !saved_cpu.booted;
    try t.expect(!std.meta.eql(base, oracle.core(cpu)));
    cpu.* = saved_cpu;

    cpu.exclusive = if (saved_cpu.exclusive) |addr| addr ^ 4 else 0x2000_8000;
    try t.expect(!std.meta.eql(base, oracle.core(cpu)));
    cpu.* = saved_cpu;

    try t.expect(cpu.active.push(.{ .number = 19, .priority = 0x20 }));
    try t.expect(!std.meta.eql(base, oracle.core(cpu)));
    cpu.* = saved_cpu;
    try t.expectEqual(base, oracle.core(cpu));
}

test "COMMON NC-01 and NC-02 all 59 Cortex registers FP security and Second units on both cores" {
    var h = try ra8.session.harness.open(t.allocator, t.io, .{ .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops), .elf_path = ipc_elf, .history_frames = 2 });
    defer h.deinit();
    var second: ra8.session.cpu1.bringup.Cpu1 = .{};
    try second.open(t.allocator, t.io, ra8.host.session_files.reader(ra8.session.file_ops.Reader), &h, ipc1_elf);
    defer second.close(t.allocator);

    // NC-01: CPU0 all 59 Cortex registers + hidden/FP/banked/active state
    try verifyAll59CortexAndHidden(h.primaryCpu());
    const before_cap = try oracle.capture(&h);
    h.primaryCpu().regs.low[0] ^= 1;
    try changed(before_cap, try oracle.capture(&h), "cores");
    h.primaryCpu().regs.low[0] ^= 1;

    // NC-02: CPU1 all 59 Cortex registers + hidden state + Second private units
    try verifyAll59CortexAndHidden(second.cpu());
    second.cpu().fp.bank.s[31] ^= 1;
    try changed(before_cap, try oracle.capture(&h), "cores");
    second.cpu().fp.bank.s[31] ^= 1;

    const base_sec = oracle.secondUnits(&second.pair);
    second.pair.second.regions.ctrl ^= 1;
    try t.expect(!std.meta.eql(base_sec, oracle.secondUnits(&second.pair)));
    second.pair.second.regions.ctrl ^= 1;

    second.pair.second.partitions.ctrl ^= 1;
    try t.expect(!std.meta.eql(base_sec, oracle.secondUnits(&second.pair)));
    second.pair.second.partitions.ctrl ^= 1;

    second.pair.second.state.timebase.ticks ^= 1;
    try t.expect(!std.meta.eql(base_sec, oracle.secondUnits(&second.pair)));
    second.pair.second.state.timebase.ticks ^= 1;

    second.pair.ns_timebase.ticks ^= 1;
    try t.expect(!std.meta.eql(base_sec, oracle.secondUnits(&second.pair)));
    second.pair.ns_timebase.ticks ^= 1;

    second.pair.core.pending.last_non_secure = 7;
    try changed(before_cap, try oracle.capture(&h), "second_units");
    second.pair.core.pending.last_non_secure = null;
    try same(before_cap, try oracle.capture(&h));
}

test "COMMON NC-03 and NC-04 all 12 SpaceId backing spaces component storage and TrustZone aliases" {
    var h = try ra8.session.harness.open(t.allocator, t.io, .{ .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops), .elf_path = ipc_elf, .history_frames = 2 });
    defer h.deinit();
    var second: ra8.session.cpu1.bringup.Cpu1 = .{};
    try second.open(t.allocator, t.io, ra8.host.session_files.reader(ra8.session.file_ops.Reader), &h, ipc1_elf);
    defer second.close(t.allocator);

    const cpu0_store = &h.state.cpu0.store.?;
    const cpu1_store = &second.pair.store.?;
    try cpu0_store.extra.map(0x9000_0000, 0x1000);
    const board = h.board();
    const blk: ra8.components.sd_card.image.Block = @splat(0x5a);
    try t.expect(board.sd.img.write(7, &blk));
    try t.expect(board.host_card.img.write(19, &blk));
    board.panel.planes.resize(.{ .width = 16, .height = 8 });
    try t.expect(board.panel.planes.ready());
    try board.options.otp.written.put(0x0300_a100, 0x3c);
    var usb_disk = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    board.usb.stick.disk = &usb_disk;
    defer board.usb.stick.disk = &.{};
    const base_spaces = try oracle.spaces.spacesDigest(t.allocator, cpu0_store, cpu1_store, board, null);
    // NC-03: Flip last byte of every single one of the 12 SpaceId spaces directly in raw memory
    const raw_targets = [_][]u8{
        cpu0_store.mutRegion(memmap.mram_base).?,
        cpu0_store.mutRegion(memmap.dtcm_base).?,
        cpu0_store.mutRegion(memmap.sram_base).?,
        cpu0_store.port.?.sdram,
        cpu0_store.mutRegion(memmap.ppb_base).?,
        cpu1_store.mutRegion(memmap.mram_base).?,
        cpu1_store.mutRegion(memmap.dtcm_base).?,
        cpu1_store.mutRegion(memmap.ppb_base).?,
        cpu0_store.extra.windows[0].?.bytes,
        board.nor.inverted,
        board.sd.img.blocks.get(7).?,
        board.panel.planes.image.pixels,
        board.host_card.img.blocks.get(19).?,
        board.panel.planes.glass.pixels,
        &usb_disk,
    };
    for (raw_targets) |slice| {
        slice[slice.len - 1] ^= 1;
        try t.expect(!std.meta.eql(base_spaces, try oracle.spaces.spacesDigest(t.allocator, cpu0_store, cpu1_store, board, null)));
        slice[slice.len - 1] ^= 1;
    }
    try board.options.otp.written.put(0x0300_a100, 0x3d);
    try t.expect(!std.meta.eql(base_spaces, try oracle.spaces.spacesDigest(t.allocator, cpu0_store, cpu1_store, board, null)));
    try board.options.otp.written.put(0x0300_a100, 0x3c);
    try t.expectEqual(base_spaces, try oracle.spaces.spacesDigest(t.allocator, cpu0_store, cpu1_store, board, null));

    // NC-04: Break TrustZone NS_MRAM / NS_SRAM aliases and cross-core shared SRAM borrow
    const base_cap = try oracle.capture(&h);
    const ns_mram_orig = cpu0_store.pages[1].?;
    const detached_mram = try t.allocator.dupe(u8, ns_mram_orig);
    defer t.allocator.free(detached_mram);
    cpu0_store.pages[1] = detached_mram;
    try changed(base_cap, try oracle.capture(&h), "aliases");
    cpu0_store.pages[1] = ns_mram_orig;

    const borrowed_sram = cpu1_store.pages[3].?;
    const detached_sram = try t.allocator.dupe(u8, borrowed_sram);
    defer t.allocator.free(detached_sram);
    cpu1_store.pages[3] = detached_sram;
    cpu1_store.pages[4] = detached_sram;
    try changed(base_cap, try oracle.capture(&h), "aliases");
    cpu1_store.pages[3] = borrowed_sram;
    cpu1_store.pages[4] = borrowed_sram;
    try same(base_cap, try oracle.capture(&h));
}

test "COMMON NC-05 and NC-07 lossless PPM frame and continuous ITM UART stream negative controls" {
    var h = try ra8.session.harness.open(t.allocator, t.io, .{ .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops), .elf_path = dfu_elf, .history_frames = 2 });
    defer h.deinit();
    const board = h.board();
    board.asks.attached_eink = &board.panel;
    board.panel.planes.resize(.{ .width = 32, .height = 16 });
    try t.expect(board.panel.planes.ready());
    board.panel.planes.glass.pixels[0] = 0x70;
    const before = try oracle.capture(&h);
    var img = try h.session().frame(t.allocator);
    defer img.deinit(t.allocator);
    const at = h.grid().at;
    var expected_frames: oracle.Stream = .{};
    try expected_frames.frame(t.allocator, at, img);
    try same(before, try oracle.capture(&h));

    // NC-05: 1-bit pixel flip, virtual_ns shift, Position shift, missing frame, duplicate frame
    for (0..5) |kind| {
        var wrong: oracle.Stream = .{};
        var pos = at;
        if (kind == 0) img.pixels[img.pixels.len - 1] ^= 1;
        if (kind == 1) img.virtual_ns += 1;
        if (kind == 2) pos.o += 1;
        if (kind != 3) try wrong.frame(t.allocator, pos, img);
        if (kind == 4) try wrong.frame(t.allocator, pos, img);
        try t.expect(!std.meta.eql(expected_frames.digest(), wrong.digest()));
        if (kind == 0) img.pixels[img.pixels.len - 1] ^= 1;
        if (kind == 1) img.virtual_ns -= 1;
    }

    // NC-07: ITM & UART stream byte, channel, virtual_ns, Position, drop, and reorder controls
    var expected_out: oracle.Stream = .{};
    expected_out.append(0, at, 1000, "itm: boot\n");
    expected_out.append(1, at, 1005, "uart: ready\n");
    for (0..6) |kind| {
        var wrong: oracle.Stream = .{};
        var pos = at;
        if (kind == 3) pos.r += 1;
        if (kind == 5) {
            wrong.append(1, at, 1005, "uart: ready\n");
            wrong.append(0, at, 1000, "itm: boot\n");
        } else {
            if (kind != 4) wrong.append(
                if (kind == 1) 9 else 0,
                pos,
                if (kind == 2) 1001 else 1000,
                if (kind == 0) "itm: booT\n" else "itm: boot\n",
            );
            wrong.append(1, at, 1005, "uart: ready\n");
        }
        try t.expect(!std.meta.eql(expected_out.digest(), wrong.digest()));
    }
}

test "COMMON NC-06 passive capture scheduler carry peripheral and attachment fault controls" {
    var h = try ra8.session.harness.open(t.allocator, t.io, .{ .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops), .elf_path = ipc_elf, .history_frames = 2 });
    defer h.deinit();

    const gauge_ep: ra8.components.endpoint.Endpoint = .{ .i2c = .{ .line = .riic, .address = 0x36 } };
    try h.session().plug(.cpu0, gauge_ep, ra8.components.parts.gauge_name);
    try h.session().setFault(.cpu0, gauge_ep, .{ .nack_every = 3 });

    var snap_before = try savedSnapshot(&h);
    defer snap_before.deinit();
    const touched_before = h.state.cpu0.store.?.touched;
    const counters_before = h.board().bus.counters;
    const formed_before = h.primaryCpu().blocks.?.formed;

    const base = try oracle.capture(&h);
    try same(base, try oracle.capture(&h));

    var snap_after = try savedSnapshot(&h);
    defer snap_after.deinit();
    try t.expectEqualSlices(u8, snap_before.written(), snap_after.written());
    try t.expectEqualDeep(touched_before, h.state.cpu0.store.?.touched);
    try t.expectEqualDeep(counters_before, h.board().bus.counters);
    try t.expectEqual(formed_before, h.primaryCpu().blocks.?.formed);

    // NC-06: Scheduler carry, timebases, lengths, Position, and Ended
    h.state.edge.saved.stretch.carry ^= 1;
    try changed(base, try oracle.capture(&h), "scheduler");
    h.state.edge.saved.stretch.carry ^= 1;

    h.state.edge.timebase.ticks ^= 1;
    try changed(base, try oracle.capture(&h), "scheduler");
    h.state.edge.timebase.ticks ^= 1;

    h.state.edge.saved.lengths[0] ^= 1;
    try changed(base, try oracle.capture(&h), "scheduler");
    h.state.edge.saved.lengths[0] ^= 1;

    inline for (.{ "branch", "r", "o" }) |field| {
        @field(h.state.edge.saved.at, field) ^= 1;
        try changed(base, try oracle.capture(&h), "position");
        @field(h.state.edge.saved.at, field) ^= 1;
    }
    const ended_cap = try oracle.captureWith(t.allocator, &h, .count, null);
    try changed(base, ended_cap, "scheduler");

    // Fabric, Debug/ITM/NVIC, Peripherals (C6/GT911/MMIO), and Attachments/Fault wrapper
    const fab = ra8.board.external.backing.fabricOf(&h.state.cpu0.store.?).?;
    fab.pending[0] ^= 1;
    try changed(base, try oracle.capture(&h), "fabric");
    fab.pending[0] ^= 1;

    const m0 = try h.session().machine(.cpu0);
    try m0.itm.text.appendSlice("x");
    try changed(base, try oracle.capture(&h), "debug_units");
    m0.itm.text.len = 0;

    h.board().wire.panel.pointer ^= 1;
    try changed(base, try oracle.capture(&h), "peripherals");
    h.board().wire.panel.pointer ^= 1;

    h.board().c6.reply[0] ^= 1;
    try changed(base, try oracle.capture(&h), "peripherals");
    h.board().c6.reply[0] ^= 1;

    try h.session().setFault(.cpu0, gauge_ep, .{ .nack_every = 5 });
    try changed(base, try oracle.capture(&h), "attachments");
    try h.session().setFault(.cpu0, gauge_ep, .{ .nack_every = 3 });
    try same(base, try oracle.capture(&h));
}

fn checkContinuation(path: []const u8, second_path: ?[]const u8) !void {
    var sink: fakes.Sink = .{ .gpa = t.allocator };
    defer sink.deinit();
    var objects: fakes.Objects = .{ .gpa = t.allocator };
    defer objects.deinit();

    var live = try ra8.session.harness.open(t.allocator, t.io, .{
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
        .elf_path = path,
        .history_frames = 2,
        .history_storage = sink.storage(),
        .history_objects = objects.objects(),
    });
    defer live.deinit();
    var sec_live: ra8.session.cpu1.bringup.Cpu1 = .{};
    if (second_path) |p| try sec_live.open(t.allocator, t.io, ra8.host.session_files.reader(ra8.session.file_ops.Reader), &live, p);
    defer if (second_path != null) sec_live.close(t.allocator);

    var plain = try ra8.session.harness.open(t.allocator, t.io, .{ .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops), .elf_path = path, .history_frames = 2 });
    defer plain.deinit();
    var sec_plain: ra8.session.cpu1.bringup.Cpu1 = .{};
    if (second_path) |p| try sec_plain.open(t.allocator, t.io, ra8.host.session_files.reader(ra8.session.file_ops.Reader), &plain, p);
    defer if (second_path != null) sec_plain.close(t.allocator);

    const init_budget: usize = if (second_path != null) 100_000 else 30_000;
    const next_budget: usize = if (second_path != null) 20_000 else 10_000;
    try fixture.continued(&live, init_budget);
    try fixture.continued(&plain, init_budget);
    if (second_path != null) {
        try t.expect(sec_live.cpu().retired > 100);
        try t.expect(live.board().mailbox.channels[2].pushes > 0);
    } else {
        const sym = ra8.session.symbols.addressOf(live.image(), "_tx_thread_current_ptr") orelse return error.NoThreadX;
        try t.expect(try live.guest().readWord(sym) != 0);
    }
    try same(try oracle.capture(&plain), try oracle.capture(&live));
    try live.state.persistent.?.checkpoints.checkpointNow();
    try live.state.persistent.?.recorder.force();
    try t.expect(sink.bytes.items.len > 0);
    var ckpt = try savedSnapshot(&live);
    defer ckpt.deinit();
    try fixture.continued(&plain, next_budget);
    try live.state.files.readFrom(ckpt.written());
    try fixture.continued(&live, next_budget);
    try same(try oracle.capture(&plain), try oracle.capture(&live));
    var fresh = try ra8.session.harness.open(t.allocator, t.io, .{ .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops), .elf_path = path, .history_frames = 2 });
    defer fresh.deinit();
    var sec_fresh: ra8.session.cpu1.bringup.Cpu1 = .{};
    if (second_path) |p| try sec_fresh.open(t.allocator, t.io, ra8.host.session_files.reader(ra8.session.file_ops.Reader), &fresh, p);
    defer if (second_path != null) sec_fresh.close(t.allocator);
    try fresh.state.files.readFrom(ckpt.written());
    try fixture.continued(&fresh, next_budget);
    try same(try oracle.capture(&plain), try oracle.capture(&fresh));
}

test "COMMON real dual-core IPC and ThreadX recording on off live and fresh continuation" {
    try checkContinuation(ipc_elf, ipc1_elf);
    try checkContinuation(threadx_elf, null);
}
