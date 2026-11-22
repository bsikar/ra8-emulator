//! Covers src/session/decomp/emit_format.zig.
const std = @import("std");
const ra8 = @import("ra8");

const decomp = ra8.session.decomp;
const elf = ra8.board.image.elf;

const uart_elf_bytes = @embedFile("../../fixtures/uart/uart_irq_echo.elf");

test "ParsedDisasm splits width suffixes and nested memory brackets" {
    const p1 = decomp.emit_format.ParsedDisasm.parse("add.w r3, r7, #0x14");
    try std.testing.expectEqualStrings("add", p1.mnemonic);
    try std.testing.expectEqual(@as(usize, 3), p1.ops().len);
    try std.testing.expectEqualStrings("#0x14", p1.ops()[2]);

    const p2 = decomp.emit_format.ParsedDisasm.parse("str r3, [r7, #0x14]");
    try std.testing.expectEqual(@as(usize, 2), p2.ops().len);
    try std.testing.expectEqualStrings("[r7, #0x14]", p2.ops()[1]);
}

test "writeConstant, writeCondition, and writeValue format constants, conditions, and ELF symbols" {
    const image = try elf.Image.init(uart_elf_bytes);
    const banner_sym = ra8.session.symbols.symbolOf(image, "k_uart_irq_banner") orelse return error.MissingSym;

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try decomp.emit_format.writeConstant(&w, image, banner_sym.value, true);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "k_uart_irq_banner") != null);

    var cbuf: [128]u8 = undefined;
    var cw: std.Io.Writer = .fixed(&cbuf);
    const origin: decomp.value.FlagOrigin = .{
        .setter_insn = 0,
        .setter_addr = 0x100,
        .kind = .cmp,
        .lhs_reg = 3,
        .rhs_imm = 0,
    };
    try decomp.emit_format.writeCondition(&cw, null, 1, origin, null);
    try std.testing.expectEqualStrings("r3 != 0", cw.buffered());

    var sbuf: [64]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&sbuf);
    try decomp.emit_format.writeCondition(&sw, null, 0, null, 2);
    try std.testing.expectEqualStrings("r2 == 0", sw.buffered());

    var vbuf: [64]u8 = undefined;
    var vw: std.Io.Writer = .fixed(&vbuf);
    try decomp.emit_format.writeValue(&vw, null, .{ .sp_offset = -16 }, 2);
    try std.testing.expectEqualStrings("sp - 0x10", vw.buffered());
}
