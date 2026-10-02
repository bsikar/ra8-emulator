//! Tests for CPU1's `--trace-rtos` (src/debug/rtos_second.zig): a tracer
//! made for core 1 and attached to an engine of its own takes that engine's
//! stores to the pointer, tagged cpu1 and stamped from that core's clock.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const nvic = ra8.periph.nvic;
const rtos_hook = ra8.core.step_hook.rtos_hook;
const Engine = ra8.core.engine.Engine;

const pointer: u32 = memmap.sram_base + 0x1ABC;
const thread: u32 = memmap.sram_base + 0x10F0;
const code: u32 = memmap.sram_base + 0x40;
// str r1, [r0]   then   b .
const store_then_park = [_]u8{ 0x01, 0x60, 0xfe, 0xe7 };

test "a core-1 tracer armed on its own engine records that engine's switch as cpu1" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try core.write(code, &store_then_park);
    try core.setRegister(.r0, pointer);
    try core.setRegister(.r1, thread);
    const clock: u64 = 7;
    const interrupts = nvic.Nvic{ .vector_base = memmap.sram_base };
    const tracer = try rtos_hook.attach(core.handle, .{ .address = pointer, .core = 1 }, &clock, &interrupts);
    defer std.heap.page_allocator.destroy(tracer);
    _ = try core.runChunk(code, 3, null);
    const events = tracer.trace.list();
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqual(@as(u1, 1), events[0].core);
    try std.testing.expectEqual(thread, events[0].thread);
    try std.testing.expectEqual(@as(u64, 7), events[0].when);
}
