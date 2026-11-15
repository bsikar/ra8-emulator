//! Host RPC tests for session.set_var (RA8EMU-1245) on uart_irq_echo.elf
//! and on a stripped (No-DWARF) copy preserving .symtab/.strtab.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const wire = ra8.rpc.session.set_var_wire;
const handler = ra8.rpc.session.set_var;
const elf = ra8.board.image.elf;

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
const sci_init: u32 = 0x0200_1974;

fn imageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    return harness.loadedImage(if (core == 0) .cpu0 else .cpu1);
}

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoImage;
}

fn stripDebugSections(bytes: []u8) !void {
    const image = try elf.Image.init(bytes);
    const hdr = image.header();
    if (hdr.e_shoff == 0 or hdr.e_shstrndx >= hdr.e_shnum) return error.MissingSections;
    const sh = ra8.session.symbols.SectionHeader;
    const shstr_off = hdr.e_shoff + @as(u32, hdr.e_shstrndx) * @sizeOf(sh);
    const shstr = std.mem.bytesAsValue(sh, bytes[shstr_off..][0..@sizeOf(sh)]).*;
    const slice = bytes[shstr.sh_offset..][0..shstr.sh_size];
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, slice, i, ".debug_")) |pos| {
        @memcpy(slice[pos..][0..7], ".strip_");
        i = pos + 7;
    }
}

fn invoke(opened: *ra8.session.harness.Harness, scratch: []u8, frame: u32, name: []const u8, value: []const u8) !wire.SetVarReply {
    var context: server.Context = .{
        .session = opened.session(),
        .scratch = scratch,
        .mapping = .{ .context = opened, .mapFn = noMap, .imageFn = imageOf },
    };
    return switch (handler.setVar(&context, .{ .core = .cpu0, .frame = frame, .name = name, .value = value })) {
        .ok => |reply| reply,
        .err => error.Refused,
    };
}

test "setVar updates globals and locals on uart_irq_echo.elf and rejects invalid targets" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = image_path,
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();
    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);
    for (0..6) |_| _ = try session.run(.cpu0, .step);

    var scratch: [proto.max_payload]u8 = undefined;

    const g4 = try invoke(&opened, &scratch, 0, "g_uart_irq_echoes", "0x1234");
    try std.testing.expectEqual(wire.SetVarStatus.ok, g4.status);
    try std.testing.expectEqual(wire.SetVarScope.global, g4.scope);
    var rb4: [4]u8 = undefined;
    try session.read(.cpu0, 0x2200_0034, &rb4);
    try std.testing.expectEqual(@as(u32, 0x1234), std.mem.readInt(u32, &rb4, .little));

    const l1 = try invoke(&opened, &scratch, 0, "channel", "7");
    try std.testing.expectEqual(wire.SetVarStatus.ok, l1.status);
    try std.testing.expectEqual(wire.SetVarScope.local, l1.scope);
    var rb1: [1]u8 = undefined;
    try session.read(.cpu0, l1.address, &rb1);
    try std.testing.expectEqual(@as(u8, 7), rb1[0]);

    const ovf = try invoke(&opened, &scratch, 0, "channel", "300");
    try std.testing.expectEqual(wire.SetVarStatus.overflow, ovf.status);

    const unk = try invoke(&opened, &scratch, 0, "no_such_var", "1");
    try std.testing.expectEqual(wire.SetVarStatus.unknown_variable, unk.status);

    const agg = try invoke(&opened, &scratch, 0, "k_uart_irq_banner", "1");
    try std.testing.expectEqual(wire.SetVarStatus.unsupported_type, agg.status);
}

test "setVar works for globals in a stripped No-DWARF ELF and reports locals unavailable" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image_path, gpa, .limited(4 << 20));
    defer gpa.free(orig);
    try stripDebugSections(orig);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stripped.elf", .data = orig });
    const stripped_path = try tmp.dir.realPathFileAlloc(std.testing.io, "stripped.elf", gpa);
    defer gpa.free(stripped_path);

    var opened = try ra8.session.harness.open(gpa, std.testing.io, .{
        .elf_path = stripped_path,
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();
    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);

    var scratch: [proto.max_payload]u8 = undefined;
    const g = try invoke(&opened, &scratch, 0, "g_uart_irq_echoes", "77");
    try std.testing.expectEqual(wire.SetVarStatus.ok, g.status);
    var rb: [4]u8 = undefined;
    try session.read(.cpu0, 0x2200_0034, &rb);
    try std.testing.expectEqual(@as(u32, 77), std.mem.readInt(u32, &rb, .little));

    const l = try invoke(&opened, &scratch, 0, "channel", "2");
    try std.testing.expectEqual(wire.SetVarStatus.no_dwarf, l.status);
    try std.testing.expect(std.mem.indexOf(u8, l.message, "DWARF") != null);
}
