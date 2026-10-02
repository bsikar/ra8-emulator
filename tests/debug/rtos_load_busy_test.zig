//! RA8EMU-268: CPU load checked against busy loops of known length, on both
//! cores. Each core runs its own engine with a two-thread loop that names a
//! thread in the current-thread pointer, spins a known count, names the
//! other, spins again, and goes round. The tracer is attached the way a run
//! attaches it (rtos_hook.attach), so the load is charged in instructions
//! counted by the engine's per-instruction hook.
//!
//! One round is 2*a + 2*b + 5 instructions: thread A holds the core from its
//! store to B's (2*a + 2: the store, the count, the spin) and B from its
//! store round to A's (2*b + 3: the same plus the branch back).
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const nvic = ra8.periph.nvic;
const rtos_hook = ra8.core.step_hook.rtos_hook;
const rtos_load = rtos_hook.load;
const Engine = ra8.core.engine.Engine;

const pointer: u32 = memmap.sram_base + 0x1ABC;
const thread_a: u32 = memmap.sram_base + 0x10F0;
const thread_b: u32 = memmap.sram_base + 0x11A0;
const code: u32 = memmap.sram_base + 0x40;
const rounds: u32 = 100;
/// Percentage points a share may sit from the known split.
const tolerance: f64 = 1.0;

/// str r1,[r0]; movs r3,#a; 1: subs r3,#1; bne 1b; str r2,[r0];
/// movs r3,#b; 2: subs r3,#1; bne 2b; b start
fn program(a: u8, b: u8) [18]u8 {
    return .{ 0x01, 0x60, a, 0x23, 0x01, 0x3B, 0xFD, 0xD1, 0x02, 0x60, b, 0x23, 0x01, 0x3B, 0xFD, 0xD1, 0xF6, 0xE7 };
}

fn share(load: *const rtos_load.Load, core: u1, thread: u32) f64 {
    for (load.rows(core)) |slot| {
        if (slot.owner.kind == .thread and slot.owner.id == thread) {
            return @as(f64, @floatFromInt(slot.ticks)) * 100.0 / @as(f64, @floatFromInt(load.total(core)));
        }
    }
    return 0;
}

fn check(core_index: u1, a: u8, b: u8) !void {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    const bytes = program(a, b);
    try core.write(code, &bytes);
    try core.setRegister(.r0, pointer);
    try core.setRegister(.r1, thread_a);
    try core.setRegister(.r2, thread_b);
    const clock: u64 = 0;
    const interrupts = nvic.Nvic{ .vector_base = memmap.sram_base };
    const tracer = try rtos_hook.attach(core.handle, .{ .address = pointer, .core = core_index }, &clock, &interrupts);
    defer std.heap.page_allocator.destroy(tracer);
    const per_round: u32 = 2 * @as(u32, a) + 2 * @as(u32, b) + 5;
    _ = try core.runChunk(code, rounds * per_round, null);

    var load = tracer.trace.load;
    load.finish(tracer.trace.loadNow(0));
    try std.testing.expectEqual(@as(u64, rounds * per_round), load.total(core_index));
    const want_a = @as(f64, @floatFromInt(2 * @as(u32, a) + 2)) * 100.0 / @as(f64, @floatFromInt(per_round));
    const want_b = @as(f64, @floatFromInt(2 * @as(u32, b) + 3)) * 100.0 / @as(f64, @floatFromInt(per_round));
    try std.testing.expectApproxEqAbs(want_a, share(&load, core_index, thread_a), tolerance);
    try std.testing.expectApproxEqAbs(want_b, share(&load, core_index, thread_b), tolerance);
    // The other core saw no event, so none of its time is any thread's.
    const other: u1 = if (core_index == 0) 1 else 0;
    try std.testing.expectEqual(@as(f64, 0), share(&load, other, thread_a));
    try std.testing.expectEqual(@as(f64, 0), share(&load, other, thread_b));
}

test "CPU0: a 3:1 busy split is reported as 3:1" {
    try check(0, 90, 30);
}

test "CPU1: a 1:3 busy split is reported as 1:3" {
    try check(1, 30, 90);
}

test "the load table names the core and adds up to 100.0%" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    const bytes = program(50, 50);
    try core.write(code, &bytes);
    try core.setRegister(.r0, pointer);
    try core.setRegister(.r1, thread_a);
    try core.setRegister(.r2, thread_b);
    const clock: u64 = 0;
    const interrupts = nvic.Nvic{ .vector_base = memmap.sram_base };
    const tracer = try rtos_hook.attach(core.handle, .{ .address = pointer, .core = 1 }, &clock, &interrupts);
    defer std.heap.page_allocator.destroy(tracer);
    _ = try core.runChunk(code, 10 * 205, null);
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.report.load(out.writer(), tracer, NoNames{});
    try std.testing.expect(std.mem.startsWith(u8, out.items, "  cpu load cpu1 : 2050 instruction(s)\n"));
    var tenths: u64 = 0;
    var lines = std.mem.splitScalar(u8, out.items, '\n');
    while (lines.next()) |line| {
        const percent = std.mem.indexOfScalar(u8, line, '%') orelse continue;
        const text = std.mem.trim(u8, line[0..percent], " ");
        const dot = std.mem.indexOfScalar(u8, text, '.').?;
        tenths += try std.fmt.parseInt(u64, text[0..dot], 10) * 10 + try std.fmt.parseInt(u64, text[dot + 1 ..], 10);
    }
    try std.testing.expectEqual(@as(u64, 1000), tenths);
}

/// Memory with no thread names in it.
const NoNames = struct {
    pub fn read(_: NoNames, _: u32, _: []u8) bool {
        return false;
    }
};
