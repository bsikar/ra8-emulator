//! Strict guest-state restoration, including CPU1 and late failures.
const std = @import("std");
const ra8 = @import("ra8");
const snap = ra8.session.board.state;
const file = ra8.snapshot.file;
const memmap = ra8.chip.core.memmap;
const GuestBus = ra8.chip.core.cpu.memory.guest.bus.GuestBus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Store = ra8.chip.core.cpu.memory.store.Store;
const at = memmap.sram_base + 0x400;

const fixture = @import("state_fixture.zig");
const Rig = fixture.Rig;
const populated = fixture.populated;

test "state strict dual-core live and fresh restoration have identical guest bytes" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    var saved = try live.save();
    defer saved.deinit();
    live.store.span(at, 4).?[0] = 99;
    live.store.span(at + 0x2000, 4).?[0] = 88;
    live.pair.store.?.span(memmap.mram_base + 0x1000, 4).?[0] = 99;
    live.machines[0].fpb = .{};
    live.pair.second.state.held = false;
    live.session.live.started = false;
    live.session.live.other.?.clock.count = .{};
    live.cpu.slots = 999;
    live.cpu.sync_entries = 88;
    live.cpu.booted = false;
    live.pair.core.cpu.slots = 777;
    live.pair.core.cpu.booted = false;
    try live.files.readFrom(saved.written());
    try std.testing.expect(live.session.live.started and live.pair.second.state.held);
    try std.testing.expectEqual(@as(u32, 8), live.session.live.other.?.clock.count.ran);
    var restored = try live.save();
    defer restored.deinit();
    try std.testing.expectEqualSlices(u8, saved.written(), restored.written());
    const fresh = try Rig.create();
    defer fresh.destroy();
    try fresh.files.readFrom(saved.written());
    var fresh_bytes = try fresh.save();
    defer fresh_bytes.deinit();
    try std.testing.expectEqualSlices(u8, restored.written(), fresh_bytes.written());
    try std.testing.expect(fresh.cpu.booted and fresh.pair.core.cpu.booted);
    try std.testing.expectEqual(@as(u64, 121), fresh.cpu.slots);
    try std.testing.expectEqual(@as(u64, 4), fresh.cpu.sync_entries);
    try std.testing.expectEqual(@as(u64, 209), fresh.pair.core.cpu.slots);
    try std.testing.expectEqual(@as(u64, 9), fresh.pair.core.cpu.sync_entries);
    try std.testing.expectEqual(@as(u8, 0), live.store.span(at + 0x2000, 1).?[0]);
    try std.testing.expectEqual(@as(u32, 0xffffffff), fresh.board.bus.read(0x4fff_ff04, 4));
    try std.testing.expectEqual(@as(u32, 0x55), fresh.board.bus.read(0x4fff_ff00, 4));
    try std.testing.expect(live.pair.store.?.span(at, 1).?.ptr == live.store.span(at, 1).?.ptr);
}

fn fakeLookup(_: ?*anyopaque, _: ?std.Io, _: []const u8, _: *[ra8.components.esp_hosted.dns.max_answers][4]u8) !u8 {
    return 0;
}

fn malformed(bytes: []const u8, kind: file.Kind) !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer out.deinit();
    try file.writeHeader(&out.writer);
    var reader = try file.Reader.open(bytes);
    while (try reader.next()) |section| {
        try file.writeSectionHeader(&out.writer, section.kind, if (section.kind == kind) 0 else section.payload.len);
        if (section.kind != kind) try out.writer.writeAll(section.payload);
    }
    return out;
}

/// `bytes` with every section of `kind` left out, or written twice.
fn recount(bytes: []const u8, kind: file.Kind, copies: usize) !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer out.deinit();
    try file.writeHeader(&out.writer);
    var reader = try file.Reader.open(bytes);
    while (try reader.next()) |section| {
        for (0..if (section.kind == kind) copies else 1) |_| {
            try file.writeSectionHeader(&out.writer, section.kind, section.payload.len);
            try out.writer.writeAll(section.payload);
        }
    }
    return out;
}

test "state strict missing and duplicated sections are refused with the live run unchanged" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    var saved = try live.save();
    defer saved.deinit();
    live.pair.core.cpu.regs.low[3] = 0x3333;
    live.pair.store.?.span(memmap.mram_base + 0x3000, 1).?[0] = 66;
    live.board.bus.write(0x4fff_ff08, 4, 0x77);
    var before = try live.save();
    defer before.deinit();
    const kinds = [_]file.Kind{ .part, .time, .security, .c6, .memory, .second_memory, .cpu, .registry, .image, .board_inputs, .systick, .stretch, .second, .debug_units, .session_runtime };
    for (kinds) |kind| for ([_]usize{ 0, 2 }) |copies| {
        var bad = try recount(saved.written(), kind, copies);
        defer bad.deinit();
        try std.testing.expect(bad.written().len != saved.written().len);
        try std.testing.expect(std.meta.isError(live.files.readFrom(bad.written())));
        var after = try live.save();
        defer after.deinit();
        try std.testing.expectEqualSlices(u8, before.written(), after.written());
    };
    var whole = try recount(saved.written(), .cpu, 1);
    defer whole.deinit();
    try live.files.readFrom(whole.written());
}

test "state strict malformed later sections and identity errors leave the live run unchanged" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    var saved = try live.save();
    defer saved.deinit();
    live.cpu.regs.low[7] = 0x5555;
    live.store.span(at + 0x2000, 1).?[0] = 77;
    live.machines[0].fpb.enabled = false;
    var before = try live.save();
    defer before.deinit();
    for ([_]file.Kind{ .memory, .cpu, .time, .panel, .storage, .c6, .registry, .systick, .stretch, .second_memory, .second, .debug_units, .board_inputs, .session_runtime }) |kind| {
        var bad = try malformed(saved.written(), kind);
        defer bad.deinit();
        try std.testing.expect(std.meta.isError(live.files.readFrom(bad.written())));
        var after = try live.save();
        defer after.deinit();
        try std.testing.expectEqualSlices(u8, before.written(), after.written());
    }
    live.files.image = "different ELF for same part";
    try std.testing.expectError(error.ImageMismatch, live.files.readFrom(saved.written()));
    live.files.image = "same immutable ELF";
    var after = try live.save();
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
}

test "state strict allocation failure is atomic and debugger points survive restore" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    var saved = try live.save();
    defer saved.deinit();
    _ = try live.machines[0].addBreak(.{ .address = at });
    const next_id = live.machines[0].next_id;
    var before = try live.save();
    defer before.deinit();
    live.board.c6.wire.bridge.resolver.lookupFn = fakeLookup;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    live.board.nor.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, live.files.readFrom(saved.written()));
    live.board.nor.allocator = std.testing.allocator;
    // The registry is the last board section: everything staged before it is released.
    var late = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    live.board.bus.cells.allocator = late.allocator();
    try std.testing.expectError(error.OutOfMemory, live.files.readFrom(saved.written()));
    live.board.bus.cells.allocator = std.testing.allocator;
    try std.testing.expect(live.board.c6.wire.bridge.resolver.lookupFn == fakeLookup);
    var after = try live.save();
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
    try live.files.readFrom(saved.written());
    try std.testing.expect(live.board.c6.wire.bridge.resolver.lookupFn == fakeLookup);
    try std.testing.expectEqual(next_id, live.machines[0].next_id);
    try std.testing.expectEqual(@as(usize, 1), live.machines[0].breaks.len);
    try std.testing.expect(!live.drivers[0].unit_dirty);
}

test "state strict restore invalidates tracked blocks and the current walker" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    live.cpu.banked.current = .secure;
    var saved = try live.save();
    defer saved.deinit();
    const cache = try std.testing.allocator.create(ra8.chip.core.cpu.decode.block_cache.BlockCache);
    defer std.testing.allocator.destroy(cache);
    cache.init();
    live.cpu.blocks = cache;
    @memcpy(live.store.span(at, 2).?, &[_]u8{ 0x02, 0x20 }); // MOVS r0,#2
    try std.testing.expect(live.cpu.step() == null);
    try std.testing.expectEqual(@as(u32, 2), live.cpu.regs.low[0]);
    try std.testing.expect(cache.formed > 0);
    try live.files.readFrom(saved.written());
    try std.testing.expectEqual(@as(u64, 0), cache.formed);
    try std.testing.expect(cache.current == null);
    try std.testing.expect(live.cpu.step() == null);
    try std.testing.expectEqual(@as(u32, 1), live.cpu.regs.low[0]);
}

test "state strict identity validates both actual loaded ELF byte sequences before any restore" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    const elf0 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(elf0);
    const elf1 = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf", std.testing.allocator, .limited(16 * 1024 * 1024));
    defer std.testing.allocator.free(elf1);
    var images: [2]?[]u8 = .{ elf0, elf1 };
    live.files.images = &images;
    var saved = try live.save();
    defer saved.deinit();
    live.cpu.regs.low[7] = 0x1234;
    live.pair.core.cpu.regs.low[6] = 0x5678;
    var before = try live.save();
    defer before.deinit();
    for ([_][]u8{ elf0, elf1 }) |image| {
        const original = image[image.len - 1];
        image[image.len - 1] ^= 1;
        try std.testing.expectError(error.ImageMismatch, live.files.readFrom(saved.written()));
        image[image.len - 1] = original;
        var after = try live.save();
        defer after.deinit();
        try std.testing.expectEqualSlices(u8, before.written(), after.written());
    }
    try live.files.readFrom(saved.written());
    var after = try live.save();
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, saved.written(), after.written());
}

fn capture(opened: *ra8.session.harness.Harness) !std.Io.Writer.Allocating {
    var writer = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer writer.deinit();
    try opened.state.files.writeTo(&writer.writer);
    return writer;
}

test "state strict actual ThreadX and dual IPC continue against an uninterrupted reference" {
    const Case = struct { cpu0: []const u8, cpu1: ?[]const u8 };
    for ([_]Case{
        .{ .cpu0 = "tests/fixtures/threadx/threadx_stkof.elf", .cpu1 = null },
        .{ .cpu0 = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf", .cpu1 = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf" },
    }) |case| {
        var live = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = case.cpu0, .history_frames = 2 });
        defer live.deinit();
        var live_second: ra8.session.cpu1.bringup.Cpu1 = .{};
        if (case.cpu1) |path| try live_second.open(std.testing.allocator, std.testing.io, &live, path);
        defer if (case.cpu1 != null) live_second.close(std.testing.allocator);
        var reference = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = case.cpu0, .history_frames = 2 });
        defer reference.deinit();
        var reference_second: ra8.session.cpu1.bringup.Cpu1 = .{};
        if (case.cpu1) |path| try reference_second.open(std.testing.allocator, std.testing.io, &reference, path);
        defer if (case.cpu1 != null) reference_second.close(std.testing.allocator);
        std.debug.print("fixture start {s}\n", .{case.cpu0});
        try fixture.continued(&live, 100_000);
        try fixture.continued(&reference, 100_000);
        if (case.cpu1 != null) {
            std.debug.print("IPC activity retired={d}, pc={x}, pushes={d}\n", .{ live_second.cpu().retired, live.primaryCpu().regs.pc, live.board().mailbox.channels[2].pushes });
            try std.testing.expect(live_second.cpu().retired > 100);
            try std.testing.expect(live.primaryCpu().regs.pc >= 0x1208_0000 and live.primaryCpu().regs.pc < 0x1209_0000);
            try std.testing.expect(live.board().mailbox.channels[2].pushes > 0 and live.board().mailbox.channels[0].pops > 0);
        } else {
            const current = ra8.session.symbols.addressOf(live.image(), "_tx_thread_current_ptr") orelse return error.NoThreadX;
            std.debug.print("ThreadX current {x}\n", .{try live.guest().readWord(current)});
            try std.testing.expect(try live.guest().readWord(current) != 0);
        }
        try fixture.sameGuest(&live, &reference);
        var saved = try capture(&live);
        defer saved.deinit();
        try fixture.continued(&live, 20_000);
        try fixture.continued(&reference, 20_000);
        try live.state.files.readFrom(saved.written());
        var restored = try capture(&live);
        defer restored.deinit();
        try std.testing.expectEqualSlices(u8, saved.written(), restored.written());
        try fixture.continued(&live, 20_000);
        try fixture.sameGuest(&live, &reference);
        var fresh = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = case.cpu0, .history_frames = 2 });
        defer fresh.deinit();
        var fresh_second: ra8.session.cpu1.bringup.Cpu1 = .{};
        if (case.cpu1) |path| try fresh_second.open(std.testing.allocator, std.testing.io, &fresh, path);
        defer if (case.cpu1 != null) fresh_second.close(std.testing.allocator);
        try fresh.state.files.readFrom(saved.written());
        var cold = try capture(&fresh);
        defer cold.deinit();
        try std.testing.expectEqualSlices(u8, saved.written(), cold.written());
        try fixture.continued(&fresh, 20_000);
        try fixture.sameGuest(&fresh, &reference);
        try fixture.cacheOracle(&fresh, capture);
    }
}

test "state strict formats five and six are refused before live guest state or host wiring changes" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    live.board.c6.wire.bridge.resolver.lookupFn = fakeLookup;
    var before = try live.save();
    defer before.deinit();
    const old = try std.testing.allocator.dupe(u8, before.written());
    defer std.testing.allocator.free(old);
    for ([_]u32{ 5, 6 }) |version| {
        std.mem.writeInt(u32, old[file.magic.len..][0..4], version, .little);
        try std.testing.expectError(error.BadVersion, live.files.readFrom(old));
    }
    var after = try live.save();
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
    try std.testing.expect(live.board.c6.wire.bridge.resolver.lookupFn == fakeLookup);
}

test "state strict full malformed DWT and expander values preserve guest debug and host wiring" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    live.pair.core.cpu.profile = ra8.chip.core.part.cpu1_profile;
    live.machines[1].dwt.numcomp = 4;
    live.board.c6.wire.bridge.resolver.lookupFn = fakeLookup;
    _ = try live.machines[0].addBreak(.{ .address = at + 2 });
    live.machines[0].mode = .running;
    live.machines[0].resumed = true;
    var before = try live.save();
    defer before.deinit();
    const debug = (try file.Reader.find(before.written(), .debug_units)).?;
    for ([_]u4{ 9, 15, 5, 8 }, 0..) |invalid, trial| {
        var cursor: ra8.snapshot.fields.Cursor = .{ .bytes = debug.payload };
        const count = try ra8.snapshot.fields.read(u8, &cursor);
        var units: [2]snap.Units = undefined;
        for (&units) |*unit| unit.* = try ra8.snapshot.fields.read(snap.Units, &cursor);
        units[if (trial < 2) @as(usize, 0) else 1].dwt.numcomp = invalid;
        units[if (trial < 2) @as(usize, 0) else 1].dwt.trcena = true;
        var payload = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer payload.deinit();
        try ra8.snapshot.fields.write(&payload.writer, count);
        for (units) |unit| try ra8.snapshot.fields.write(&payload.writer, unit);
        var bad = try fixture.replacement(before.written(), .debug_units, payload.written());
        defer bad.deinit();
        try std.testing.expectEqual(before.written().len, bad.written().len);
        try std.testing.expectError(error.BadValue, live.files.readFrom(bad.written()));
    }
    live.board.wire.expander.pointer = 255;
    live.board.wire.expander.pointed = true;
    var wire = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer wire.deinit();
    try file.writeHeader(&wire.writer);
    try ra8.board.snapshot.wire.save(&live.board, &wire.writer);
    live.board.wire.expander.pointer = 0;
    live.board.wire.expander.pointed = false;
    var bad = try fixture.replacement(before.written(), .wire, (try file.Reader.find(wire.written(), .wire)).?.payload);
    defer bad.deinit();
    try std.testing.expectError(error.BadValue, live.files.readFrom(bad.written()));
    var after = try live.save();
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
    try std.testing.expect(live.machines[0].mode == .running and live.machines[0].resumed);
    try std.testing.expectEqual(@as(usize, 1), live.machines[0].breaks.len);
    try std.testing.expect(live.board.c6.wire.bridge.resolver.lookupFn == fakeLookup);
}

test "state strict late impossible gesture and unordered event values are atomic" {
    const live = try Rig.create();
    defer live.destroy();
    try populated(live);
    live.board.c6.wire.bridge.resolver.lookupFn = fakeLookup;
    var before = try live.save();
    defer before.deinit();
    const script = live.board.input_script;
    for (0..3) |trial| {
        live.board.input_script = .{};
        if (trial < 2) {
            try live.board.input_script.parse(if (trial == 0) "at 1ms swipe 0 0 1 1 1s" else "at 1ms longpress 0 0 1s");
            live.board.input_script.cursor = 1;
            live.board.input_script.now_ns = live.board.time.base.now();
            live.board.input_script.active = if (trial == 0) .{ .swipe = .{ .from = .{ .x = 0, .y = 0 }, .to = .{ .x = 1, .y = 1 }, .start = 100, .duration = 1_000_000_000, .next = 0 } } else .{ .longpress = .{ .point = .{ .x = 0, .y = 0 }, .start = 100, .duration = 1_000_000_000, .next = 0 } };
            if (live.board.input_script.active) |*active| switch (active.*) {
                .swipe => |*s| {
                    s.start = live.board.time.base.now() + 100;
                    s.next = 0;
                },
                .longpress => |*s| {
                    s.start = live.board.time.base.now() + 100;
                    s.next = 0;
                },
            };
        } else {
            try live.board.input_script.parse("at 1s tap 0 0\nat 2s tap 1 1");
            live.board.input_script.events[1].at_ns = 0;
        }
        var encoded = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer encoded.deinit();
        try file.writeHeader(&encoded.writer);
        try ra8.board.snapshot.board.inputs.save(&live.board, &encoded.writer);
        live.board.input_script = script;
        var bad = try fixture.replacement(before.written(), .board_inputs, (try file.Reader.find(encoded.written(), .board_inputs)).?.payload);
        defer bad.deinit();
        try std.testing.expectError(error.BadValue, live.files.readFrom(bad.written()));
    }
    // Input encoding above deliberately used a copy of parser state only.
    var after = try live.save();
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
    try std.testing.expect(live.board.c6.wire.bridge.resolver.lookupFn == fakeLookup);
}
