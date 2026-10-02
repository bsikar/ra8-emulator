//! Tests for src/debug/rtos_hook.zig: which stores the hook takes for a
//! switch, what an image without ThreadX gets, and what the report prints.
const std = @import("std");
const ra8 = @import("ra8");
const rtos_hook = ra8.core.step_hook.rtos_hook;

fn bareImage(buffer: *[@sizeOf(ra8.core.elf.Header)]u8) !ra8.core.elf.Image {
    @memset(buffer, 0);
    const head: *align(1) ra8.core.elf.Header = std.mem.bytesAsValue(ra8.core.elf.Header, buffer);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.e_machine = ra8.core.elf.em_arm;
    return ra8.core.elf.Image.init(buffer);
}

test "a full word to the pointer is a switch, anything else is not" {
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    tracer.onStore(0x2200_1ABC, 4, 0x2200_10F0);
    tracer.onStore(0x2200_1ABE, 2, 0x1234);
    tracer.onStore(0x2200_1ABC, 1, 0);
    try std.testing.expectEqual(@as(usize, 1), tracer.trace.list().len);
    try std.testing.expectEqual(@as(u32, 0x2200_10F0), tracer.trace.list()[0].thread);
}

test "each switch is stamped from the run's clock as it lands" {
    var ticks: u64 = 3;
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC, .now = &ticks };
    tracer.onStore(0x2200_1ABC, 4, 0x2200_10F0);
    ticks = 9;
    tracer.onStore(0x2200_1ABC, 4, 0);
    try std.testing.expectEqual(@as(u64, 3), tracer.trace.list()[0].when);
    try std.testing.expectEqual(@as(u64, 9), tracer.trace.list()[1].when);
}

test "no flag traces nothing, and an image without ThreadX traces nothing" {
    var buffer: [@sizeOf(ra8.core.elf.Header)]u8 = undefined;
    const image = try bareImage(&buffer);
    try std.testing.expect(rtos_hook.resolve(image, false) == null);
    try std.testing.expect(rtos_hook.resolve(image, true) == null);
}

test "the report lists the opening switches of threadx_blink in order" {
    // The pointer values threadx_blink.elf writes in its first 3M
    // instructions: the scheduler idles, runs one thread, idles, runs the
    // other, idles.
    var tracer = rtos_hook.Tracer{ .address = 0x2200_1ABC };
    for ([_]u32{ 0, 0x2200_10F0, 0, 0x2200_11A0, 0 }) |value| tracer.onStore(0x2200_1ABC, 4, value);
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.print(out.writer(), &tracer);
    const want =
        \\  rtos trace    : _tx_thread_current_ptr @0x22001ABC, 5 switch(es)
        \\                  tick 0 cpu0 idle
        \\                  tick 0 cpu0 -> 0x220010F0
        \\                  tick 0 cpu0 idle
        \\                  tick 0 cpu0 -> 0x220011A0
        \\                  tick 0 cpu0 idle
        \\
    ;
    try std.testing.expectEqualStrings(want, out.items);
}

test "no trace asked for prints nothing" {
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try rtos_hook.print(out.writer(), null);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
