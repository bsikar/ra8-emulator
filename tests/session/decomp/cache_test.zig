//! Covers src/session/decomp/cache.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;
const elf = ra8.board.image.elf;

const uart_elf_bytes = @embedFile("../../fixtures/uart/uart_irq_echo.elf");

test "CfgCache resolves addresses inside functions, tracks hits/misses, and prewarms uart_irq_echo.elf" {
    const gpa = std.testing.allocator;
    const image = try elf.Image.init(uart_elf_bytes);
    var cache = try decomp.cache.CfgCache.init(gpa, image, .{});
    defer cache.deinit();

    const main_sym = ra8.session.symbols.symbolOf(image, "main") orelse return error.MissingMain;
    const main_first = try cache.get(main_sym.value);
    const main_mid = try cache.get((main_sym.value & ~@as(u32, 1)) + 8);
    try std.testing.expectEqual(main_first, main_mid);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);

    const total = try cache.prewarmAll();
    try std.testing.expectEqual(cache.extents.len, total);
    try std.testing.expect(total >= 200);

    // Invalidating drops cached CFGs while preserving symbol extents
    cache.invalidate();
    const after_inv = try cache.get(main_sym.value);
    try std.testing.expectEqual(main_sym.value & ~@as(u32, 1), after_inv.entry);

    // Dataflow converges and emits cleanly across every seeded function in uart_irq_echo.elf with zero leaks
    for (cache.extents) |ext| {
        const df = try cache.getDataflow(ext.entry);
        try std.testing.expect(df.converged);
        const em = try cache.getEmit(ext.entry);
        try std.testing.expectEqual(ext.entry, em.entry);
    }
    try std.testing.expectEqual(after_inv.entry, (try cache.getDataflow(main_sym.value)).defs[0].address);
    try std.testing.expect(cache.extentEntry(main_sym.value) != null);
}
