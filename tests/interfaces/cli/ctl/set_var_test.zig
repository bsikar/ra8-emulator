//! End-to-end tests for `ctl set NAME=VALUE` over TCP RPC (RA8EMU-1245),
//! using tcp:127.0.0.1:0 so tests run cleanly on Windows without Unix sockets.
const std = @import("std");
const ra8 = @import("ra8");
const serve_peer = @import("../serve_peer.zig");
const ctl_run = @import("../ctl_run.zig");
const elf = ra8.board.image.elf;
const Term = std.process.Child.Term;

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

fn expectOkRun(gpa: std.mem.Allocator, spec: []const u8, words: []const []const u8) !void {
    var ans = try ctl_run.run(gpa, spec, words);
    defer ans.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, ans.term);
}

test "ctl set writes global and local variables on uart_irq_echo.elf and reports actionable errors" {
    const gpa = std.testing.allocator;
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen("tcp:127.0.0.1:0", &line);
    defer served.child.kill(std.testing.io);
    const spec = served.bound;

    try expectOkRun(gpa, spec, &.{ "load", ctl_run.uart_image });
    try expectOkRun(gpa, spec, &.{ "break", "0x02001974" });
    try expectOkRun(gpa, spec, &.{ "run", "--budget", "200000" });
    for (0..6) |_| try expectOkRun(gpa, spec, &.{"step"});

    // Global 4-byte scalar write + memory verification.
    var g = try ctl_run.run(gpa, spec, &.{ "set", "g_uart_irq_echoes=0x1234" });
    defer g.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, g.term);
    const g_obj = g.field("set_var").object;
    try std.testing.expectEqualStrings("global", g_obj.get("scope").?.string);

    var gmem = try ctl_run.run(gpa, spec, &.{ "mem", "0x22000034", "4" });
    defer gmem.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, gmem.term);
    try std.testing.expectEqualStrings("34120000", gmem.field("hex").string);

    // Local 1-byte uint8_t write + memory verification.
    var loc = try ctl_run.run(gpa, spec, &.{ "set", "channel=7" });
    defer loc.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, loc.term);
    const l_obj = loc.field("set_var").object;
    try std.testing.expectEqualStrings("local", l_obj.get("scope").?.string);
    const addr = try ctl_run.expectInteger(l_obj.get("address").?);
    const addr_hex = try std.fmt.allocPrint(gpa, "0x{x}", .{addr});
    defer gpa.free(addr_hex);

    var lmem = try ctl_run.run(gpa, spec, &.{ "mem", addr_hex, "1" });
    defer lmem.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, lmem.term);
    try std.testing.expectEqualStrings("07", lmem.field("hex").string);

    // Overflow and unknown variable return exit 1 and actionable JSON error.
    var ovf = try ctl_run.run(gpa, spec, &.{ "set", "channel=300" });
    defer ovf.deinit();
    try std.testing.expectEqual(Term{ .exited = 1 }, ovf.term);
    try std.testing.expectEqualStrings("overflow", ovf.field("status").string);

    var unk = try ctl_run.run(gpa, spec, &.{ "set", "no_such_var=1" });
    defer unk.deinit();
    try std.testing.expectEqual(Term{ .exited = 1 }, unk.term);
    try std.testing.expectEqualStrings("unknown_variable", unk.field("status").string);
}

test "ctl set writes globals on a stripped No-DWARF ELF and refuses locals clearly" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const orig = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, ctl_run.uart_image, gpa, .limited(4 << 20));
    defer gpa.free(orig);
    try stripDebugSections(orig);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "stripped.elf", .data = orig });
    const stripped_path = try tmp.dir.realPathFileAlloc(std.testing.io, "stripped.elf", gpa);
    defer gpa.free(stripped_path);

    var line: [256]u8 = undefined;
    var served = try serve_peer.listen("tcp:127.0.0.1:0", &line);
    defer served.child.kill(std.testing.io);
    const spec = served.bound;

    try expectOkRun(gpa, spec, &.{ "load", stripped_path });
    try expectOkRun(gpa, spec, &.{ "break", "0x02001974" });
    try expectOkRun(gpa, spec, &.{ "run", "--budget", "200000" });

    var g = try ctl_run.run(gpa, spec, &.{ "set", "g_uart_irq_echoes=77" });
    defer g.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, g.term);

    var gmem = try ctl_run.run(gpa, spec, &.{ "mem", "0x22000034", "4" });
    defer gmem.deinit();
    try std.testing.expectEqual(Term{ .exited = 0 }, gmem.term);
    try std.testing.expectEqualStrings("4d000000", gmem.field("hex").string);

    var loc = try ctl_run.run(gpa, spec, &.{ "set", "channel=3" });
    defer loc.deinit();
    try std.testing.expectEqual(Term{ .exited = 1 }, loc.term);
    try std.testing.expectEqualStrings("no_dwarf", loc.field("status").string);
}
