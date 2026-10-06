//! Public harness tests against ra8-ui commit
//! 92c693ebf8dbfb9d7b88a68e71a99954c5fbaef9. The fixture was copied from
//! zig-out/image/ra8_ui.elf and stripped with arm-none-eabi-strip --strip-debug.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");

const image_path = "tests/fixtures/display/ra8_ui.elf";
const input_path = "tests/fixtures/display/tap.input";

test "public harness opens real display firmware, taps, settles, and frames" {
    if (builtin.mode != .ReleaseFast) return error.SkipZigTest;
    var opened = try ra8.harness.open(std.testing.allocator, .{
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

test "public harness rejects a zero settle window before opening the image" {
    const result = ra8.harness.open(std.testing.allocator, .{
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
    try tmp.dir.writeFile(.{ .sub_path = "bad.elf", .data = "not an elf" });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/bad.elf", .{tmp.sub_path});
    const result = ra8.harness.open(std.testing.allocator, .{ .elf_path = path });
    if (result) |opened_value| {
        var opened = opened_value;
        opened.deinit();
        return error.ExpectedTruncated;
    } else |err| try std.testing.expect(err == error.Truncated);
}

test "public harness streams ThreadX switches and exceptions in time order" {
    var opened = try ra8.harness.open(std.testing.allocator, .{ .elf_path = "tests/fixtures/threadx/threadx_stkof.elf" });
    defer opened.deinit();
    try std.testing.expect(opened.traceRtos());
    const session = opened.session();
    const id = try session.subscribe();
    session.live.budget = 2_000_000;
    _ = try session.run(.cpu0, .cont);

    var events: [256]ra8.core.session_event_stream.Event = undefined;
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
    var opened = try ra8.harness.open(std.testing.allocator, .{ .elf_path = image_path });
    defer opened.deinit();
    try std.testing.expect(!opened.traceRtos());
}
