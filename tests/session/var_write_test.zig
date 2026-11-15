//! Tests for variable resolution, typed value encoding, and memory/register
//! mutation in src/session/var_write.zig.
const std = @import("std");
const ra8 = @import("ra8");

const bus = ra8.chip.core.cpu.bus;
const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const Session = ra8.session.api.Session;
const stop_machine = ra8.session.stop_machine;
const var_write = ra8.session.var_write;
const vars = ra8.session.dwarf.vars;
const elf = ra8.board.image.elf;
const symbols = ra8.session.symbols;
const Builder = @import("symbol_image.zig").Builder;

const Sram = struct {
    base: u32 = 0x2200_0000,
    bytes: [4096]u8 = @splat(0),

    fn view(self: *Sram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Sram = @ptrCast(@alignCast(ctx));
        if (address < self.base) return error.Unmapped;
        const off = address - self.base;
        if (@as(usize, off) + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[off..][0..into.len]);
    }

    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Sram = @ptrCast(@alignCast(ctx));
        if (address < self.base) return error.Unmapped;
        const off = address - self.base;
        if (@as(usize, off) + from.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[off..][0..from.len], from);
    }
};

test "encodeValue encodes signed, unsigned, float, bool, and untyped scalars little-endian" {
    var buf: [8]u8 = undefined;

    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, try var_write.encodeValue("-1", 4, .signed, &buf));
    try std.testing.expectEqualSlices(u8, &.{0x80}, try var_write.encodeValue("-128", 1, .signed, &buf));
    try std.testing.expectError(error.Overflow, var_write.encodeValue("128", 1, .signed, &buf));
    try std.testing.expectError(error.Overflow, var_write.encodeValue("-129", 1, .signed, &buf));

    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, try var_write.encodeValue("0x1234", 2, .unsigned, &buf));
    try std.testing.expectError(error.Overflow, var_write.encodeValue("-1", 4, .unsigned, &buf));
    try std.testing.expectError(error.Overflow, var_write.encodeValue("256", 1, .unsigned, &buf));

    const f32_bytes = try var_write.encodeValue("1.5", 4, .float, &buf);
    try std.testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(std.mem.readInt(u32, f32_bytes[0..4], .little))));
    const f64_bytes = try var_write.encodeValue("-0.25", 8, .float, &buf);
    try std.testing.expectEqual(@as(f64, -0.25), @as(f64, @bitCast(std.mem.readInt(u64, f64_bytes[0..8], .little))));
    try std.testing.expectError(error.Overflow, var_write.encodeValue("1e50", 4, .float, &buf));
    try std.testing.expectError(error.InvalidValue, var_write.encodeValue("nan_txt", 4, .float, &buf));
    try std.testing.expectError(error.UnsupportedWidth, var_write.encodeValue("1.5", 2, .float, &buf));

    try std.testing.expectEqualSlices(u8, &.{1}, try var_write.encodeValue("true", 1, .boolean, &buf));
    try std.testing.expectEqualSlices(u8, &.{0}, try var_write.encodeValue("false", 1, .boolean, &buf));
    try std.testing.expectError(error.Overflow, var_write.encodeValue("2", 1, .boolean, &buf));
    try std.testing.expectError(error.InvalidValue, var_write.encodeValue("yes", 1, .boolean, &buf));

    // Untyped (no DWARF) accepts both negative two's complement and hex unsigned within width.
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0xff }, try var_write.encodeValue("-1", 2, .untyped, &buf));
    try std.testing.expectEqualSlices(u8, &.{ 0xef, 0xbe, 0xad, 0xde }, try var_write.encodeValue("0xdeadbeef", 4, .untyped, &buf));
    try std.testing.expectError(error.InvalidValue, var_write.encodeValue("1.5", 4, .untyped, &buf));
    try std.testing.expectError(error.InvalidValue, var_write.encodeValue("", 4, .untyped, &buf));
    try std.testing.expectError(error.UnsupportedWidth, var_write.encodeValue("1", 3, .unsigned, &buf));
}

fn markSym(buffer: []u8, index: usize, kind: u8, size: u32) void {
    const at = Builder.sym_off + @sizeOf(symbols.Symbol) * index;
    const entry: *align(1) symbols.Symbol =
        std.mem.bytesAsValue(symbols.Symbol, buffer[at..][0..@sizeOf(symbols.Symbol)]);
    entry.st_info = kind;
    entry.st_size = size;
}

test "var_write writes globals in stripped No-DWARF images and reports locals unavailable" {
    var buffer: [1024]u8 = undefined;
    const bytes = Builder.build(&buffer, &.{ "g_word", "g_byte", "fn_entry", "g_unmapped" }, &.{ 0x2200_0100, 0x2200_0110, 0x2200_0200, 0x9000_0000 });
    markSym(&buffer, 0, symbols.symbol_type.object, 4);
    markSym(&buffer, 1, symbols.symbol_type.object, 1);
    markSym(&buffer, 2, symbols.symbol_type.func, 16);
    markSym(&buffer, 3, symbols.symbol_type.object, 4);
    const image = try elf.Image.init(bytes);

    var sram: Sram = .{};
    var cpu: Cpu = .{ .bus = sram.view() };
    var machine: stop_machine.Machine = .{};
    var session: Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };

    const ok = try var_write.set(&session, .cpu0, image, 0, "g_word", "0x12345678");
    try std.testing.expectEqual(var_write.Status.ok, ok.status);
    try std.testing.expectEqual(var_write.Scope.global, ok.scope);
    try std.testing.expectEqual(@as(u32, 0x2200_0100), ok.address);
    try std.testing.expectEqual(@as(u32, 4), ok.size);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), std.mem.readInt(u32, sram.bytes[0x100..][0..4], .little));

    const neg = try var_write.set(&session, .cpu0, image, 0, "g_byte", "-1");
    try std.testing.expectEqual(var_write.Status.ok, neg.status);
    try std.testing.expectEqual(@as(u8, 0xff), sram.bytes[0x110]);

    const fn_res = try var_write.set(&session, .cpu0, image, 0, "fn_entry", "1");
    try std.testing.expectEqual(var_write.Status.unsupported_type, fn_res.status);

    const unmapped = try var_write.set(&session, .cpu0, image, 0, "g_unmapped", "1");
    try std.testing.expectEqual(var_write.Status.write_failed, unmapped.status);

    const no_dwarf = try var_write.set(&session, .cpu0, image, 0, "missing_local", "1");
    try std.testing.expectEqual(var_write.Status.no_dwarf, no_dwarf.status);
}

test "var_write mutates locals and globals in uart_irq_echo.elf and rejects read-only targets" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/uart/uart_irq_echo.elf",
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();
    const session = opened.session();
    const image = opened.image();

    // Break inside ra8_sci_init and step past prologue so CFA / frame are active.
    _ = try session.setBreakpoint(.cpu0, .{ .address = 0x0200_1974 });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);
    for (0..6) |_| _ = try session.run(.cpu0, .step);

    // Local uint8_t channel in frame 0 (ra8_sci_init).
    const loc = try var_write.set(session, .cpu0, image, 0, "channel", "9");
    try std.testing.expectEqual(var_write.Status.ok, loc.status);
    try std.testing.expectEqual(var_write.Scope.local, loc.scope);
    try std.testing.expectEqual(@as(u32, 1), loc.size);
    var rb1: [1]u8 = undefined;
    try session.read(.cpu0, loc.address, &rb1);
    try std.testing.expectEqual(@as(u8, 9), rb1[0]);

    // Overflow against uint8_t local.
    const ovf = try var_write.set(session, .cpu0, image, 0, "channel", "300");
    try std.testing.expectEqual(var_write.Status.overflow, ovf.status);

    // Non-scalar struct local in caller frame 1 (uart_irq_setup_or_halt -> clk_core).
    const agg = try var_write.set(session, .cpu0, image, 1, "clk_core", "1");
    try std.testing.expectEqual(var_write.Status.unsupported_type, agg.status);

    // Scalar local in caller frame 1 (uart_irq_setup_or_halt -> pclka_hz, uint32_t fbreg -16).
    const caller_loc = try var_write.set(session, .cpu0, image, 1, "pclka_hz", "123456");
    try std.testing.expectEqual(var_write.Status.ok, caller_loc.status);
    var rb4: [4]u8 = undefined;
    try session.read(.cpu0, caller_loc.address, &rb4);
    try std.testing.expectEqual(@as(u32, 123456), std.mem.readInt(u32, &rb4, .little));

    // Mutable RAM global (g_uart_irq_echoes) writes cleanly and reads back.
    const glob = try var_write.set(session, .cpu0, image, 0, "g_uart_irq_echoes", "0x1234");
    try std.testing.expectEqual(var_write.Status.ok, glob.status);
    try std.testing.expectEqual(var_write.Scope.global, glob.scope);
    try session.read(.cpu0, glob.address, &rb4);
    try std.testing.expectEqual(@as(u32, 0x1234), std.mem.readInt(u32, &rb4, .little));

    const missing = try var_write.set(session, .cpu0, image, 0, "no_such_var_anywhere", "1");
    try std.testing.expectEqual(var_write.Status.unknown_variable, missing.status);
    _ = vars;
}

fn buildDwarfElf(alloc: std.mem.Allocator, info: []const u8, abbrev: []const u8, df: []const u8) ![]u8 {
    // Shstrtab: "\0.debug_info\0.debug_abbrev\0.debug_frame\0.shstrtab\0"
    const shstr = "\x00.debug_info\x00.debug_abbrev\x00.debug_frame\x00.shstrtab\x00";
    var w: std.Io.Writer.Allocating = .init(alloc);
    errdefer w.deinit();
    const bw = &w.writer;
    const info_off: u32 = @sizeOf(elf.Header);
    const abbr_off: u32 = info_off + @as(u32, @intCast(info.len));
    const df_off: u32 = abbr_off + @as(u32, @intCast(abbrev.len));
    const shstr_off: u32 = df_off + @as(u32, @intCast(df.len));
    const sh_off: u32 = shstr_off + @as(u32, @intCast(shstr.len));
    var hdr = std.mem.zeroes(elf.Header);
    hdr.magic = .{ 0x7f, 'E', 'L', 'F' };
    hdr.class = 1;
    hdr.data = 1;
    hdr.version = 1;
    hdr.e_machine = elf.em_arm;
    hdr.e_shoff = sh_off;
    hdr.e_shentsize = @sizeOf(symbols.SectionHeader);
    hdr.e_shnum = 5;
    hdr.e_shstrndx = 4;
    try bw.writeAll(std.mem.asBytes(&hdr));
    try bw.writeAll(info);
    try bw.writeAll(abbrev);
    try bw.writeAll(df);
    try bw.writeAll(shstr);
    const specs = [_]struct { name: u32, off: u32, size: u32 }{
        .{ .name = 0, .off = 0, .size = 0 },
        .{ .name = 1, .off = info_off, .size = @intCast(info.len) },
        .{ .name = 13, .off = abbr_off, .size = @intCast(abbrev.len) },
        .{ .name = 27, .off = df_off, .size = @intCast(df.len) },
        .{ .name = 40, .off = shstr_off, .size = shstr.len },
    };
    for (specs, 0..) |s, idx| {
        var sh = std.mem.zeroes(symbols.SectionHeader);
        sh.sh_name = s.name;
        sh.sh_type = if (idx == 4) 3 else if (idx == 0) 0 else 1;
        sh.sh_offset = s.off;
        sh.sh_size = s.size;
        try bw.writeAll(std.mem.asBytes(&sh));
    }
    return w.toOwnedSlice();
}

test "var_write handles register locals, breg+offset locals, and read-only reasons" {
    const abbrev = [_]u8{
        0x01, 0x11, 0x01, 0x03, 0x08, 0x00, 0x00,
        0x02, 0x24, 0x00, 0x03, 0x08, 0x0b, 0x0b,
        0x3e, 0x0b, 0x00, 0x00, 0x03, 0x2e, 0x01,
        0x03, 0x08, 0x11, 0x01, 0x12, 0x06, 0x40,
        0x18, 0x00, 0x00, 0x04, 0x34, 0x00, 0x03,
        0x08, 0x49, 0x13, 0x02, 0x18, 0x00, 0x00,
        0x05, 0x34, 0x00, 0x03, 0x08, 0x49, 0x13,
        0x00, 0x00,
    };
    // Build unit header + base_type int (off 11+3='c',0=14) + subprogram [0x2200_0000, +0x20) + vars.
    const dies = [_]u8{
        0x01, 'u', 0, // off 11..14
        0x02, 'i', '3', '2', 0, 4, 0x05, // off 14..21
        0x03, 'f', 0, 0x00, 0x00, 0x00, 0x22, 0x20, 0x00, 0x00, 0x00, 0x01, 0x9c, // subprogram
        0x04, 'r', '_', 'v', 'a', 'r', 0, 14, 0, 0, 0, 1, 0x55, // DW_OP_reg5
        0x04, 'b', '_', 'v', 'a', 'r', 0, 14, 0, 0, 0, 2, 0x7d, 0x10, // DW_OP_breg13 +16
        0x04, 'c', 'm', 'p', 0, 14, 0, 0, 0, 3, 0x50, 0x9d, 0x04, // composite
        0x04, 'i', 'm', 'p', 0, 14, 0, 0, 0, 2, 0x31, 0x9f, // implicit
        0x04, 'm', 'u', 'l', 0, 14, 0, 0, 0, 3, 0x91, 0x7c, 0x06, // multi_op
        0x05, 'o',  'p', 't', 0, 14, 0, 0, 0, // optimized_out
        0x00, 0x00,
    };
    var info_w: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer info_w.deinit();
    try info_w.writer.writeInt(u32, 7 + dies.len, .little);
    try info_w.writer.writeInt(u16, 4, .little);
    try info_w.writer.writeInt(u32, 0, .little);
    try info_w.writer.writeByte(4);
    try info_w.writer.writeAll(&dies);
    const elf_bytes = try buildDwarfElf(std.testing.allocator, info_w.written(), &abbrev, &.{});
    defer std.testing.allocator.free(elf_bytes);
    const image = try elf.Image.init(elf_bytes);

    var sram: Sram = .{};
    var cpu: Cpu = .{ .bus = sram.view() };
    cpu.regs.set(13, 0x2200_0200);
    cpu.regs.pc = 0x2200_0008;
    var machine: stop_machine.Machine = .{};
    var session: Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 1 } };

    const reg_res = try var_write.set(&session, .cpu0, image, 0, "r_var", "-7");
    try std.testing.expectEqual(var_write.Status.ok, reg_res.status);
    try std.testing.expectEqual(@as(u8, 5), reg_res.in_register);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -7))), try session.register(.cpu0, .r5));

    const breg_res = try var_write.set(&session, .cpu0, image, 0, "b_var", "0x11223344");
    try std.testing.expectEqual(var_write.Status.ok, breg_res.status);
    try std.testing.expectEqual(@as(u32, 0x2200_0210), breg_res.address);
    try std.testing.expectEqual(@as(u32, 0x1122_3344), std.mem.readInt(u32, sram.bytes[0x210..][0..4], .little));

    for ([_][]const u8{ "cmp", "imp", "mul", "opt" }) |ro_name| {
        const ro = try var_write.set(&session, .cpu0, image, 0, ro_name, "1");
        try std.testing.expectEqual(var_write.Status.read_only, ro.status);
        try std.testing.expect(ro.message.len > 0);
    }
}
