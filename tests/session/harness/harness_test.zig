//! Public harness tests against ra8-ui commit
//! 92c693ebf8dbfb9d7b88a68e71a99954c5fbaef9. The fixture was copied from
//! zig-out/image/ra8_ui.elf and stripped with arm-none-eabi-strip --strip-debug.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const image_path = "tests/fixtures/display/ra8_ui.elf";
const input_path = "tests/fixtures/display/tap.input";

test "public harness opens real display firmware, taps, settles, and frames" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = image_path,
        .input_script = input_path,
    });
    defer opened.deinit();

    try opened.session().waitSettled(2_000_000_000);
    var before = try opened.session().frame(std.testing.allocator);
    defer before.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1072), before.width);
    try std.testing.expectEqual(@as(u32, 1448), before.height);

    try opened.session().waitSettled(2_000_000_000);
    var after = try opened.session().frame(std.testing.allocator);
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(before.width, after.width);
    try std.testing.expectEqual(before.height, after.height);
    try std.testing.expect(after.virtual_ns > before.virtual_ns);
    try std.testing.expect(!std.mem.eql(u8, before.pixels, after.pixels));
}

test "RA8EMU-768: restore returns the session to a saved screen, frame for frame" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = "screen.ra8snap";
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path, .input_script = input_path, .state_dir = dir });
    defer opened.deinit();

    try opened.session().waitSettled(2_000_000_000);
    var saved = try opened.session().frame(std.testing.allocator);
    defer saved.deinit(std.testing.allocator);
    try opened.stateFiles().save(path);

    try opened.session().waitSettled(2_000_000_000);
    var moved = try opened.session().frame(std.testing.allocator);
    defer moved.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, saved.pixels, moved.pixels));

    try opened.stateFiles().restore(path);
    var back = try opened.session().frame(std.testing.allocator);
    defer back.deinit(std.testing.allocator);
    try std.testing.expectEqual(saved.virtual_ns, back.virtual_ns);
    try std.testing.expectEqualSlices(u8, saved.pixels, back.pixels);
}

test "public harness rejects a zero settle window before opening the image" {
    const result = ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = image_path,
        .settle_window_ns = 0,
    });
    if (result) |opened_value| {
        var opened = opened_value;
        opened.deinit();
        return error.ExpectedInvalidSettleWindow;
    } else |err| try std.testing.expect(err == error.InvalidSettleWindow);
}

test "public harness cleans up an invalid ELF" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.elf", .data = "not an elf" });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/bad.elf", .{tmp.sub_path});
    const result = ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = path });
    if (result) |opened_value| {
        var opened = opened_value;
        opened.deinit();
        return error.ExpectedTruncated;
    } else |err| try std.testing.expect(err == error.Truncated);
}

test "public harness streams ThreadX switches and exceptions in time order" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/threadx/threadx_stkof.elf" });
    defer opened.deinit();
    try std.testing.expect(opened.traceRtos());
    const session = opened.session();
    const id = try session.subscribe();
    session.live.budget = 2_000_000;
    _ = try session.run(.cpu0, .cont);

    var events: [256]ra8.session.event.stream.Event = undefined;
    const read = session.pollEvents(id, &events) orelse return error.NoEvents;
    var switches: usize = 0;
    var entries: usize = 0;
    var last: u64 = 0;
    for (events[0..read.count]) |event| {
        switch (event.kind) {
            .rtos_switch => switches += 1,
            .isr_enter => entries += 1,
            .rtos_idle, .isr_leave => {},
            else => continue,
        }
        try std.testing.expect(event.virtual_ns >= last);
        last = event.virtual_ns;
    }
    try std.testing.expect(switches > 0);
    try std.testing.expect(entries > 0);
    try std.testing.expect(last > 0);
}

test "public harness reports no RTOS trace for an image without ThreadX" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    defer opened.deinit();
    try std.testing.expect(!opened.traceRtos());
}

const StreamEvent = ra8.session.event.stream.Event;

fn isRtos(event: StreamEvent) bool {
    return switch (event.kind) {
        .rtos_switch, .rtos_idle, .isr_enter, .isr_leave => true,
        else => false,
    };
}

test "public harness streams the same RTOS events --trace-rtos records" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/threadx/threadx_stkof.elf" });
    defer opened.deinit();
    try std.testing.expect(opened.traceRtos());
    const session = opened.session();
    const id = try session.subscribe();
    var seen: [256]StreamEvent = undefined;
    var count: usize = 0;
    var batch: [128]StreamEvent = undefined;
    for (0..10) |_| {
        session.live.budget = 200_000;
        _ = try session.run(.cpu0, .cont);
        const read = session.pollEvents(id, &batch) orelse return error.NoEvents;
        try std.testing.expectEqual(@as(u64, 0), read.dropped);
        for (batch[0..read.count]) |event| {
            if (!isRtos(event) or count == seen.len) continue;
            seen[count] = event;
            count += 1;
        }
    }
    const state = opened.state;
    const recorded = state.tracer.?.trace.list();
    const shared = @min(count, recorded.len);
    try std.testing.expect(shared > 0);
    for (seen[0..shared], recorded[0..shared]) |got, want| {
        const kind: StreamEvent.Kind = switch (want.kind) {
            .switch_to => .rtos_switch,
            .idle => .rtos_idle,
            .enter => .isr_enter,
            .leave => .isr_leave,
        };
        try std.testing.expectEqual(kind, got.kind);
        try std.testing.expectEqual(ra8.session.event.stream.Core.cpu0, got.core);
        try std.testing.expectEqual(@as(u1, 0), want.core);
        try std.testing.expectEqual(state.publisher.nsOf(want.when), got.virtual_ns);
        try std.testing.expectEqual(want.thread, got.payload.rtos.thread);
        try std.testing.expectEqual(want.exception, got.payload.rtos.exception);
    }
}

fn retiredAfter(stall: bool) !struct { retired: u64, recorded: usize, dropped: u64, total: usize } {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/threadx/threadx_stkof.elf" });
    defer opened.deinit();
    try std.testing.expect(opened.traceRtos());
    const session = opened.session();
    const id = if (stall) try session.subscribe() else null;
    session.live.budget = 2_000_000;
    _ = try session.run(.cpu0, .cont);
    var batch: [ra8.session.event.stream.capacity]StreamEvent = undefined;
    const dropped = if (id) |held| (session.pollEvents(held, &batch) orelse return error.NoEvents).dropped else 0;
    const trace = &opened.state.tracer.?.trace;
    return .{ .retired = opened.primaryCpu().retired, .recorded = trace.len, .dropped = dropped, .total = trace.len + trace.dropped };
}

test "a subscriber that never reads does not change the run" {
    const free = try retiredAfter(false);
    const stalled = try retiredAfter(true);
    try std.testing.expectEqual(free.retired, stalled.retired);
    try std.testing.expectEqual(free.recorded, stalled.recorded);
    if (stalled.total > ra8.session.event.stream.capacity) try std.testing.expect(stalled.dropped > 0);
}

test "RA8EMU-950: a session core sees CPACR, so fp_basic's first VADD lands" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/fpu/fp_basic.elf",
    });
    defer opened.deinit();
    const first_result: u32 = 0x2200_0100;
    var bytes: [4]u8 = undefined;
    var steps: usize = 0;
    while (steps < 400) : (steps += 1) {
        _ = try opened.session().step(.cpu0);
        try opened.session().read(.cpu0, first_result, &bytes);
        if (std.mem.readInt(u32, &bytes, .little) == 0x4080_0000) break;
    } else return error.SumNeverStored;
    try std.testing.expectEqual(@as(u32, 0x00F0_0000), opened.primaryCpu().fp.cpacr);
}

test "RA8EMU-1148: a session core runs under the MPU check a plain run arms" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = "tests/fixtures/threadx/threadx_stkof.elf" });
    defer opened.deinit();
    const cpu = opened.primaryCpu();
    const check = cpu.mpu orelse return error.NoMpuCheck;
    try std.testing.expect(check.unit == &opened.board().regions);
    try std.testing.expect(!check.armed);
}

test "RA8EMU-959: an image loaded over another is the one a firmware reset restarts" {
    const gpa = std.testing.allocator;
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = "tests/fixtures/gpio/blink.elf" });
    defer opened.deinit();
    const reboot = opened.board().reboot.?;
    try std.testing.expectEqual(@as(u32, 0x0200_0000), reboot.vector_base);
    // An image linked further up the MRAM, so its vector table is elsewhere.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf", gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try opened.session().load(.cpu0, bytes);
    try std.testing.expectEqual(@as(?u32, 0x020C_0000), opened.loadedImage(.cpu0).?.vectorBase());
    try std.testing.expectEqual(@as(u32, 0x020C_0000), reboot.vector_base);
}

test "RA8EMU-1152: the harness opens on the board profile it is given" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    const custom =
        \\# Test board, profile format version 1.
        \\version=1
        \\ospi=size:16777216,width:8,clock_hz:166666667,latency_cycles:8,burst:incrementing16
        \\sdram=size:8388608,width:32,clock_hz:133000000,latency_cycles:3,burst:incrementing16
        \\memory_window_cycles=1000000
        \\led=P600,0x001F,TEST LED
        \\panel=sample_480x272
    ;
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = image_path,
        .board_profile = custom,
    });
    defer opened.deinit();

    try std.testing.expectEqual(@as(u32, 16777216), opened.board().external_memory.ospi.size);
    try std.testing.expectEqual(@as(u32, 8388608), opened.board().external_memory.sdram.size);
    const profile = opened.boardProfile();
    try std.testing.expectEqualStrings("TEST LED", profile.leds[0].label);
    try std.testing.expect(profile.panel != null);
}

test "CPU VTOR regression: repeated Session CPU1 loads expose the loaded vector base" {
    const gpa = std.testing.allocator;
    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{ .elf_path = "tests/fixtures/gpio/blink.elf" });
    defer opened.deinit();
    var second: ra8.session.cpu1.bringup.Cpu1 = .{};
    try second.open(gpa, std.testing.io, &opened, "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");
    defer second.close(gpa);
    const cpu = second.cpu();
    const first = second.image.?.vectorBase().?;
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first, try cpu.bus.readWord(ra8.chip.core.memmap.scb.vtor));
    const moved = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "tests/fixtures/gpio/blink.elf", gpa, .limited(1 << 20));
    defer gpa.free(moved);
    // Bring-up loads once already. No slot separates these same-base and moved-base loads.
    for ([_][]const u8{ second.bytes, second.bytes, moved, moved, second.bytes }) |bytes| {
        const before = cpu.slots;
        try opened.session().load(.cpu1, bytes);
        const expected = (try ra8.board.image.elf.Image.init(bytes)).vectorBase().?;
        try std.testing.expect(expected != 0);
        var word: [4]u8 = undefined;
        try opened.session().read(.cpu1, ra8.chip.core.memmap.scb.vtor, &word);
        try std.testing.expectEqual(expected, std.mem.readInt(u32, &word, .little));
        try std.testing.expectEqual(expected, cpu.vtor);
        try std.testing.expectEqual(before, cpu.slots);
    }
    try std.testing.expectEqual(@as(u64, 0), cpu.slots);
    _ = try opened.session().step(.cpu1);
    try std.testing.expect(cpu.slots > 0);
    const before = cpu.slots;
    try opened.session().load(.cpu1, moved);
    try opened.session().load(.cpu1, moved);
    const base = (try ra8.board.image.elf.Image.init(moved)).vectorBase().?;
    try std.testing.expect(base != first);
    try std.testing.expectEqual(base, try cpu.bus.readWord(ra8.chip.core.memmap.scb.vtor));
    try std.testing.expectEqual(before, cpu.slots);
    try std.testing.expectEqual(@as(u32, 0), try opened.primaryCpu().bus.readWord(ra8.chip.core.memmap.scb.vtor));
}
