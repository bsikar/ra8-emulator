//! Covers src/session/decomp/extents.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;
const elf = ra8.board.image.elf;

const uart_elf_bytes = @embedFile("../../fixtures/uart/uart_irq_echo.elf");

test "extents.collect extracts deduplicated sorted functions from uart_irq_echo.elf" {
    const gpa = std.testing.allocator;
    const image = try elf.Image.init(uart_elf_bytes);
    const list = try decomp.extents.collect(gpa, image);
    defer gpa.free(list);

    try std.testing.expect(list.len >= 200);
    for (list[1..], 0..) |cur, i| {
        try std.testing.expect(list[i].entry < cur.entry);
        try std.testing.expect(cur.size > 0);
    }

    const main_sym = ra8.session.symbols.symbolOf(image, "main") orelse return error.MissingMain;
    const main_norm = main_sym.value & ~@as(u32, 1);
    const by_entry = decomp.extents.findByEntry(list, main_sym.value) orelse return error.NotFound;
    try std.testing.expectEqual(main_norm, by_entry.entry);
    try std.testing.expectEqualStrings("main", by_entry.name.?);

    const inside_main = decomp.extents.findContaining(list, main_norm + 8) orelse return error.NotContaining;
    try std.testing.expectEqual(main_norm, inside_main.entry);
    try std.testing.expect(decomp.extents.findContaining(list, 0xFFFF_FFF0) == null);
}

test "extents.resolveTarget links function symbols and tolerates synthetic alias collision" {
    const gpa = std.testing.allocator;
    const image = try elf.Image.init(uart_elf_bytes);
    const list = try decomp.extents.collect(gpa, image);
    defer gpa.free(list);

    const isr_sym = ra8.session.symbols.symbolOf(image, "ra8_isr_dispatch") orelse return error.MissingSym;
    const resolved = decomp.extents.resolveTarget(image, list, isr_sym.value);
    try std.testing.expectEqual(isr_sym.value & ~@as(u32, 1), resolved.entry);
    try std.testing.expectEqualStrings("ra8_isr_dispatch", resolved.name.?);

    const synthetic = [_]decomp.extents.FunctionExtent{
        .{ .entry = 0x100, .size = 0x100, .name = "outer" },
        .{ .entry = 0x140, .size = 0x20, .name = "inner" },
    };
    try std.testing.expectEqualStrings("inner", decomp.extents.findContaining(&synthetic, 0x150).?.name.?);
    try std.testing.expectEqualStrings("outer", decomp.extents.findContaining(&synthetic, 0x180).?.name.?);
}
