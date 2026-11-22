//! Covers src/session/decomp/image_bus.zig.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const decomp = ra8.session.decomp;
const elf = ra8.board.image.elf;

const uart_elf_bytes = @embedFile("../../fixtures/uart/uart_irq_echo.elf");

test "ImageBus reads executable code segments, refuses writes and non-exec fetches" {
    const image = try elf.Image.init(uart_elf_bytes);
    var ib: decomp.image_bus.ImageBus = .{ .image = image };
    const view = ib.view();

    const main_addr = ra8.session.symbols.addressOf(image, "main").? & ~@as(u32, 1);
    try std.testing.expect(view.allowsExec(main_addr, 2));

    const first_half = try view.fetchHalf(main_addr);
    try std.testing.expect(first_half != 0);

    var peek_buf: [4]u8 = undefined;
    try std.testing.expect(view.peek(main_addr, &peek_buf));
    try std.testing.expect(!view.peek(0xDEAD_BEE0, &peek_buf));

    try std.testing.expectError(bus.Error.Unmapped, view.write(main_addr, &.{ 0x00, 0xBF }));
    try std.testing.expectError(bus.Error.Unmapped, view.fetchHalf(0x4000_0000));
    try std.testing.expect(!view.allowsExec(0x4000_0000, 2));
}

test "ImageBus respects zero-length operations and unmapped fallback bounds" {
    var empty: decomp.image_bus.ImageBus = .{};
    const view = empty.view();
    try std.testing.expect(!view.allowsExec(0x0200_0000, 2));
    try std.testing.expect(view.allowsExec(0x0200_0000, 0));

    var out: [2]u8 = undefined;
    try std.testing.expectError(bus.Error.Unmapped, view.read(0x0200_0000, &out));
    try std.testing.expect(!view.peek(0x0200_0000, &out));
}
