//! Tests for DWARF variable location classification, type extraction,
//! lexical block resolution, frame base evaluation, and multi-CU support.
const std = @import("std");
const ra8 = @import("ra8");

const dwarf = ra8.session.dwarf;
const vars = dwarf.vars;
const locals = dwarf.locals;
const unwind = ra8.session.unwind;

// Abbrevs matching synthetic unit below:
// 1: compile_unit (children, name string)
// 2: base_type (no children, name string, byte_size data1, encoding data1)
// 3: subprogram (children, name string, low_pc addr, high_pc data4, frame_base exprloc)
// 4: variable (no children, name string, type ref4, location exprloc)
// 5: variable_const (no children, name string, type ref4, const_value sdata)
// 6: variable_noloc (no children, name string, type ref4)
// 7: variable_sec (no children, name string, type ref4, location sec_offset)
// 8: lexical_block (children, low_pc addr, high_pc data4)
// 9: typedef (no children, name string, type ref4)
// 10: structure_type (no children, name string, byte_size data1)
const test_abbrev = [_]u8{
    0x01, 0x11, 0x01, 0x03, 0x08, 0x00, 0x00,
    0x02, 0x24, 0x00, 0x03, 0x08, 0x0b, 0x0b,
    0x3e, 0x0b, 0x00, 0x00, 0x03, 0x2e, 0x01,
    0x03, 0x08, 0x11, 0x01, 0x12, 0x06, 0x40,
    0x18, 0x00, 0x00, 0x04, 0x34, 0x00, 0x03,
    0x08, 0x49, 0x13, 0x02, 0x18, 0x00, 0x00,
    0x05, 0x34, 0x00, 0x03, 0x08, 0x49, 0x13,
    0x1c, 0x0d, 0x00, 0x00, 0x06, 0x34, 0x00,
    0x03, 0x08, 0x49, 0x13, 0x00, 0x00, 0x07,
    0x34, 0x00, 0x03, 0x08, 0x49, 0x13, 0x02,
    0x17, 0x00, 0x00, 0x08, 0x0b, 0x01, 0x11,
    0x01, 0x12, 0x06, 0x00, 0x00, 0x09, 0x16,
    0x00, 0x03, 0x08, 0x49, 0x13, 0x00, 0x00,
    0x0a, 0x13, 0x00, 0x03, 0x08, 0x0b, 0x0b,
    0x00, 0x00,
};

fn writeUnit(w: *std.Io.Writer, version: u16, abbrev_off: u32, payload: []const u8) !void {
    const head: u32 = if (version >= 5) 8 else 7;
    try w.writeInt(u32, head + @as(u32, @intCast(payload.len)), .little);
    try w.writeInt(u16, version, .little);
    if (version >= 5) try w.writeAll(&.{ 0x01, 0x04 });
    try w.writeInt(u32, abbrev_off, .little);
    if (version < 5) try w.writeByte(0x04);
    try w.writeAll(payload);
}

fn writeDieStr(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll(text);
    try w.writeByte(0);
}

fn writeBaseType(w: *std.Io.Writer, name: []const u8, size: u8, enc: u8) !void {
    try w.writeByte(0x02);
    try writeDieStr(w, name);
    try w.writeByte(size);
    try w.writeByte(enc);
}

fn writeVarExpr(w: *std.Io.Writer, name: []const u8, type_off: u32, expr: []const u8) !void {
    try w.writeByte(0x04);
    try writeDieStr(w, name);
    try w.writeInt(u32, type_off, .little);
    try w.writeByte(@intCast(expr.len));
    try w.writeAll(expr);
}

fn buildSyntheticUnit(alloc: std.mem.Allocator) ![]u8 {
    var dies: std.Io.Writer.Allocating = .init(alloc);
    defer dies.deinit();
    const dw = &dies.writer;

    // Unit header = 11 bytes (v4).
    const hdr: u32 = 11;
    try dw.writeByte(0x01); // compile_unit
    try writeDieStr(dw, "test.c");

    const t_i32 = hdr + @as(u32, @intCast(dies.written().len));
    try writeBaseType(dw, "int", 4, 0x05); // DW_ATE_signed
    const t_f32 = hdr + @as(u32, @intCast(dies.written().len));
    try writeBaseType(dw, "float", 4, 0x04); // DW_ATE_float
    const t_struct = hdr + @as(u32, @intCast(dies.written().len));
    try dw.writeByte(0x0a); // structure_type
    try writeDieStr(dw, "pair");
    try dw.writeByte(8);
    const t_typedef = hdr + @as(u32, @intCast(dies.written().len));
    try dw.writeByte(0x09); // typedef -> i32
    try writeDieStr(dw, "my_i32");
    try dw.writeInt(u32, t_i32, .little);

    // Top-level global variable at 0x22000100.
    try writeVarExpr(dw, "g_val", t_f32, &.{ 0x03, 0x00, 0x01, 0x00, 0x22 });

    // Subprogram [0x1000, 0x1040), frame_base = DW_OP_call_frame_cfa (0x9c).
    try dw.writeByte(0x03);
    try writeDieStr(dw, "work");
    try dw.writeInt(u32, 0x1000, .little);
    try dw.writeInt(u32, 0x40, .little);
    try dw.writeAll(&.{ 0x01, 0x9c });

    try writeVarExpr(dw, "fb_var", t_typedef, &.{ 0x91, 0x7c }); // fbreg -4
    try writeVarExpr(dw, "reg_var", t_i32, &.{0x55}); // reg5
    try writeVarExpr(dw, "breg_var", t_i32, &.{ 0x7d, 0x08 }); // breg13 +8
    try writeVarExpr(dw, "comp_var", t_i32, &.{ 0x50, 0x9d, 0x04 }); // reg0, piece 4
    try writeVarExpr(dw, "imp_var", t_i32, &.{ 0x31, 0x9f }); // lit1, stack_value
    try writeVarExpr(dw, "multi_var", t_i32, &.{ 0x91, 0x7c, 0x06 }); // fbreg -4, deref
    try writeVarExpr(dw, "agg_var", t_struct, &.{ 0x91, 0x74 }); // fbreg -12

    // const_value
    try dw.writeByte(0x05);
    try writeDieStr(dw, "const_var");
    try dw.writeInt(u32, t_i32, .little);
    try dw.writeByte(0x07); // sdata 7

    // missing DW_AT_location -> optimized_out
    try dw.writeByte(0x06);
    try writeDieStr(dw, "opt_var");
    try dw.writeInt(u32, t_i32, .little);

    // DW_FORM_sec_offset -> location_list
    try dw.writeByte(0x07);
    try writeDieStr(dw, "loclist_var");
    try dw.writeInt(u32, t_i32, .little);
    try dw.writeInt(u32, 0x20, .little);

    // lexical_block [0x1010, 0x1020) shadowing breg_var and defining inner_var.
    try dw.writeByte(0x08);
    try dw.writeInt(u32, 0x1010, .little);
    try dw.writeInt(u32, 0x10, .little);
    try writeVarExpr(dw, "inner_var", t_f32, &.{ 0x91, 0x78 }); // fbreg -8
    try dw.writeByte(0x00); // end lexical_block

    try dw.writeByte(0x00); // end subprogram
    try dw.writeByte(0x00); // end unit

    var info: std.Io.Writer.Allocating = .init(alloc);
    errdefer info.deinit();
    try writeUnit(&info.writer, 4, 0, dies.written());
    return info.toOwnedSlice();
}

test "vars.findLocal distinguishes writable locations, encodings, scopes, and read-only reasons" {
    const info = try buildSyntheticUnit(std.testing.allocator);
    defer std.testing.allocator.free(info);
    const sections = locals.Sections{ .info = info, .abbrev = &test_abbrev };
    try std.testing.expect(vars.hasDebugInfo(sections));

    const fb = (try vars.findLocal(sections, 0x1004, "fb_var")).?;
    try std.testing.expectEqualDeep(vars.Location{ .frame = -4 }, fb.location);
    try std.testing.expectEqual(vars.Encoding.signed, fb.type_info.encoding);
    try std.testing.expectEqual(@as(u32, 4), fb.type_info.size);
    try std.testing.expect(fb.type_info.is_scalar);
    try std.testing.expectEqualSlices(u8, &.{0x9c}, fb.frame_base_expr);

    try std.testing.expectEqualDeep(vars.Location{ .in_register = 5 }, (try vars.findLocal(sections, 0x1004, "reg_var")).?.location);
    try std.testing.expectEqualDeep(vars.Location{ .register_offset = .{ .reg = 13, .offset = 8 } }, (try vars.findLocal(sections, 0x1004, "breg_var")).?.location);
    try std.testing.expectEqualDeep(vars.Location{ .read_only = .composite }, (try vars.findLocal(sections, 0x1004, "comp_var")).?.location);
    try std.testing.expectEqualDeep(vars.Location{ .read_only = .implicit_value }, (try vars.findLocal(sections, 0x1004, "imp_var")).?.location);
    try std.testing.expectEqualDeep(vars.Location{ .read_only = .multi_op }, (try vars.findLocal(sections, 0x1004, "multi_var")).?.location);
    try std.testing.expectEqualDeep(vars.Location{ .read_only = .const_value }, (try vars.findLocal(sections, 0x1004, "const_var")).?.location);
    try std.testing.expectEqualDeep(vars.Location{ .read_only = .optimized_out }, (try vars.findLocal(sections, 0x1004, "opt_var")).?.location);
    try std.testing.expectEqualDeep(vars.Location{ .read_only = .location_list }, (try vars.findLocal(sections, 0x1004, "loclist_var")).?.location);

    const agg = (try vars.findLocal(sections, 0x1004, "agg_var")).?;
    try std.testing.expect(!agg.type_info.is_scalar);
    try std.testing.expectEqual(@as(u32, 8), agg.type_info.size);

    // Lexical block scoping: inner_var visible at 0x1014, absent at 0x1004 and 0x1020.
    try std.testing.expect((try vars.findLocal(sections, 0x1004, "inner_var")) == null);
    try std.testing.expect((try vars.findLocal(sections, 0x1020, "inner_var")) == null);
    const inner = (try vars.findLocal(sections, 0x1014, "inner_var")).?;
    try std.testing.expectEqual(vars.Encoding.float, inner.type_info.encoding);
}

test "vars.findGlobal and frameBaseAddress evaluate CFA and register bases" {
    const info = try buildSyntheticUnit(std.testing.allocator);
    defer std.testing.allocator.free(info);
    const sections = locals.Sections{ .info = info, .abbrev = &test_abbrev };

    const g = (try vars.findGlobal(sections, "g_val")).?;
    try std.testing.expectEqual(vars.Encoding.float, g.type_info.encoding);
    try std.testing.expectEqualDeep(vars.Location{ .address = 0x2200_0100 }, g.location);

    // Build .debug_frame where PC 0x1000..0x1040 has CFA = r13 + 16.
    var df: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer df.deinit();
    const cie_head = [_]u8{ 0xff, 0xff, 0xff, 0xff, 4, 0, 4, 0, 0x02, 0x7c, 0x0e };
    try df.writer.writeInt(u32, cie_head.len + 3, .little);
    try df.writer.writeAll(&cie_head);
    try df.writer.writeAll(&.{ 0x0c, 0x0d, 16 });
    const fde_prog = [_]u8{};
    try df.writer.writeInt(u32, 12 + fde_prog.len, .little);
    try df.writer.writeInt(u32, 0, .little);
    try df.writer.writeInt(u32, 0x1000, .little);
    try df.writer.writeInt(u32, 0x40, .little);

    var regs = std.mem.zeroes(unwind.Registers);
    regs[13] = 0x2200_1000;
    regs[15] = 0x1004;
    const cfa_base = try vars.frameBaseAddress(df.written(), &.{0x9c}, regs);
    try std.testing.expectEqual(@as(u32, 0x2200_1010), cfa_base);
    try std.testing.expectEqual(@as(u32, 0x2200_1000), try vars.frameBaseAddress(&.{}, &.{0x5d}, regs));
    try std.testing.expectEqual(@as(u32, 0x2200_1020), try vars.frameBaseAddress(&.{}, &.{ 0x7d, 0x20 }, regs));
    try std.testing.expectError(error.MissingFrameBase, vars.frameBaseAddress(&.{}, &.{}, regs));
}

test "vars.findLocal uses each CU's own abbrev table in multi-CU images (uart_irq_echo.elf)" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/uart/uart_irq_echo.elf",
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();
    const image = opened.image();
    const sections = locals.ofImage(image);
    try std.testing.expect(vars.hasDebugInfo(sections));

    // ra8_sci_init sits in CU 6 (non-zero debug_abbrev_offset).
    const chan = (try vars.findLocal(sections, 0x0200_1978, "channel")).?;
    try std.testing.expectEqualDeep(vars.Location{ .frame = -17 }, chan.location);
    try std.testing.expectEqual(@as(u32, 1), chan.type_info.size);
    try std.testing.expectEqual(vars.Encoding.unsigned, chan.type_info.encoding);
    try std.testing.expect(chan.type_info.is_scalar);

    // uart_irq_setup_or_halt's struct clk_core is non-scalar.
    const clk = (try vars.findLocal(sections, 0x0200_04a4, "clk_core")).?;
    try std.testing.expect(!clk.type_info.is_scalar);

    // Global g_uart_irq_echoes carries unsigned encoding and 4-byte size.
    const echoes = (try vars.findGlobal(sections, "g_uart_irq_echoes")).?;
    try std.testing.expectEqual(@as(u32, 4), echoes.type_info.size);
    try std.testing.expectEqual(vars.Encoding.unsigned, echoes.type_info.encoding);
}
