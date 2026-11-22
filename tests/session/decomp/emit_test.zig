//! Covers src/session/decomp/emit.zig.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const decode = ra8.chip.core.cpu.decode;
const decomp = ra8.session.decomp;
const elf = ra8.board.image.elf;

const uart_elf_bytes = @embedFile("../../fixtures/uart/uart_irq_echo.elf");

const Rom = struct {
    base: u32,
    bytes: []const u8,

    fn view(self: *Rom) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .allowsExec = allowsExec } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Rom = @ptrCast(@alignCast(ctx));
        if (address < self.base) return bus.Error.Unmapped;
        const off = address - self.base;
        if (off + into.len > self.bytes.len) return bus.Error.Unmapped;
        @memcpy(into, self.bytes[off..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        _ = .{ ctx, address, from };
        return bus.Error.Unmapped;
    }

    fn allowsExec(ctx: *anyopaque, address: u32, len: usize) bool {
        const self: *Rom = @ptrCast(@alignCast(ctx));
        return address >= self.base and (address - self.base) + len <= self.bytes.len;
    }
};

fn emitHalfwords(halves: []const u16, entry: u32) !decomp.emit.FunctionEmit {
    const gpa = std.testing.allocator;
    const raw = try gpa.alloc(u8, halves.len * 2);
    defer gpa.free(raw);
    for (halves, 0..) |h, i| {
        std.mem.writeInt(u16, raw[i * 2 ..][0..2], h, .little);
    }
    var rom: Rom = .{ .base = entry, .bytes = raw };
    const dc = try gpa.create(decode.cache.DecodeCache);
    defer gpa.destroy(dc);
    dc.* = .{};

    var cfg = try decomp.builder.build(gpa, .{
        .bus = rom.view(),
        .decode_cache = dc,
        .entry = entry,
    });
    defer cfg.deinit();

    var df = try decomp.dataflow.analyze(gpa, &cfg, .{ .bus = rom.view() });
    defer df.deinit();

    return decomp.emit.emitFunction(gpa, &cfg, &df, .{});
}

test "emitFunction formats paired branches, IT blocks, 64-bit returns, and unresolved jumps" {
    // cmp r0,#0 (0x2800); itt eq (0xBF04); moveq r0,#1 (0x2001); bxeq lr (0x4770); movs r0,#0 (0x2000); bx lr (0x4770)
    var it_em = try emitHalfwords(&.{ 0x2800, 0xBF04, 0x2001, 0x4770, 0x2000, 0x4770 }, 0x100);
    defer it_em.deinit();
    try std.testing.expectEqualStrings("if (r0 == 0) r0 = 1", it_em.pseudoAt(0x104).?);
    try std.testing.expectEqualStrings("if (r0 == 0) return 1", it_em.pseudoAt(0x106).?);
    try std.testing.expectEqualStrings("return 0", it_em.pseudoAt(0x10A).?);

    // 64-bit return: umull r0, r1, r2, r3 (0xFBA2 0x0103); bx lr (0x4770)
    var ret64 = try emitHalfwords(&.{ 0xFBA2, 0x0103, 0x4770 }, 0x2000);
    defer ret64.deinit();
    try std.testing.expectEqualStrings("r1:r0 fn_00002000(r0, r1, r2, r3)", ret64.signature_line);
    try std.testing.expectEqualStrings("r1:r0 = r2 * r3", ret64.pseudoAt(0x2000).?);
    try std.testing.expectEqualStrings("return r1:r0", ret64.pseudoAt(0x2004).?);

    // TBB unresolved jump: tbb [r0, r1] (0xE8D0 0xF001)
    var tbb_em = try emitHalfwords(&.{ 0xE8D0, 0xF001 }, 0x3000);
    defer tbb_em.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tbb_em.pseudoAt(0x3000).?, "unresolved: table_branch") != null);
}

test "uart_irq_echo.elf emission resolves calls, folded constants, paired branches, and locals" {
    const gpa = std.testing.allocator;
    const image = try elf.Image.init(uart_elf_bytes);
    var cache = try decomp.cache.CfgCache.init(gpa, image, .{});
    defer cache.deinit();

    // uart_irq_pins_init: folded call arguments + paired conditional branch + return
    const pins_addr = ra8.session.symbols.addressOf(image, "uart_irq_pins_init").?;
    const pins_em = try cache.getEmit(pins_addr);
    const call0 = pins_em.pseudoAt(0x0200_03FC).?;
    try std.testing.expectEqualStrings("r0 = ra8_pfs_route_peripheral(0xd02, 4, 0x2002b6c)", call0);
    const branch_line = pins_em.pseudoAt(0x0200_0408).?;
    try std.testing.expect(std.mem.indexOf(u8, branch_line, "if (r3 == 0) goto uart_irq_pins_init+") != null);

    // uart_irq_setup_or_halt: void panic halt + folded BFI 0x302 + sp_offset frame arg
    const setup_addr = ra8.session.symbols.addressOf(image, "uart_irq_setup_or_halt").?;
    const setup_em = try cache.getEmit(setup_addr);
    try std.testing.expectEqualStrings("uart_irq_panic_halt()", setup_em.pseudoAt(0x0200_04B8).?);
    const second_clk = setup_em.pseudoAt(0x0200_04F8).?;
    try std.testing.expect(std.mem.indexOf(u8, second_clk, "fw_clock_rate_for(r0, 0x302, sp - 0x10)") != null);

    // memcpy & __aeabi_memcpy tail call
    const memcpy_addr = ra8.session.symbols.addressOf(image, "memcpy").?;
    const memcpy_em = try cache.getEmit(memcpy_addr);
    try std.testing.expectEqualStrings("void memcpy(r0, r1, r2)", memcpy_em.signature_line);
    const cbz_line = memcpy_em.pseudoAt(memcpy_addr & ~@as(u32, 1)).?;
    try std.testing.expectEqualStrings("if (r2 == 0) goto memcpy+0x18", cbz_line);

    const aeabi_addr = ra8.session.symbols.addressOf(image, "__aeabi_memcpy").?;
    const aeabi_em = try cache.getEmit(aeabi_addr);
    try std.testing.expectEqualStrings("memcpy()", aeabi_em.pseudoAt(aeabi_addr & ~@as(u32, 1)).?);
}
