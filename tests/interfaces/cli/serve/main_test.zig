const std = @import("std");
const cli = @import("cli_app").serve.main;

test "backend builds require an explicit absolute compiler and workspace" {
    const compiler = if (@import("builtin").os.tag == .windows) "C:/tools/zig.exe" else "/tools/zig";
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--build-zig", compiler, "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", ".", "--build-zig", "zig", "--stdio", "fw.elf" }) == null);
    const enabled = cli.parse(&.{ "ra8", "serve", "--build-zig", compiler, "--workspace", ".", "--stdio", "fw.elf" }).?;
    try std.testing.expectEqualStrings(compiler, enabled.build_zig.?);
    if (@import("builtin").os.tag == .windows) {
        try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", ".", "--build-zig", "\\tools\\zig.exe", "--stdio", "fw.elf" }) == null);
    }
}

test "serve workspace access requires one explicit nonempty root" {
    const plain = cli.parse(&.{ "ra8", "serve", "--stdio", "firmware.elf" }).?;
    try std.testing.expectEqual(@as(?[]const u8, null), plain.workspace);
    const enabled = cli.parse(&.{ "ra8", "serve", "--workspace", "project with spaces", "--stdio", "firmware.elf" }).?;
    try std.testing.expectEqualStrings("project with spaces", enabled.workspace.?);
    try std.testing.expectEqualStrings("firmware.elf", enabled.elf);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", "", "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace", "one", "--workspace", "two", "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--workspace" }) == null);
}

test "artifact serving requires one explicit nonempty spool root" {
    const plain = cli.parse(&.{ "ra8", "serve", "--stdio", "fw.elf" }).?;
    try std.testing.expect(plain.artifacts_root == null);
    const enabled = cli.parse(&.{ "ra8", "serve", "--artifacts-root", "bundle cache", "--stdio", "fw.elf" }).?;
    try std.testing.expectEqualStrings("bundle cache", enabled.artifacts_root.?);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--artifacts-root", "", "--stdio", "fw.elf" }) == null);
    try std.testing.expect(cli.parse(&.{ "ra8", "serve", "--artifacts-root" }) == null);
    const duplicate = &.{ "ra8", "serve", "--artifacts-root", "one", "--artifacts-root", "two", "--stdio", "fw.elf" };
    try std.testing.expect(cli.parse(duplicate) == null);
}

test "serve takes a machine from the catalog and refuses --cpu1 on a single-core one" {
    const machine_mod = @import("ra8").chip.core.machine;
    const single: machine_mod.Machine = .{
        .name = "single-m33",
        .label = "SINGLE-M33",
        .cores = .{ .primary = machine_mod.core.cortexM33(.{ .security = false, .fpu = .single, .systicks = 1 }) },
        .part = .ra8d2,
    };
    const list = [_]*const machine_mod.Machine{ &machine_mod.catalog.ra8d2, &single };
    const picked = cli.parseWithCatalog(&.{ "ra8", "serve", "--part", "single-m33", "--stdio", "fw.elf" }, &list).?;
    try std.testing.expectEqual(&single, picked.machine.?);
    const absent = &.{ "ra8", "serve", "--part", "single-m33", "--cpu1", "c.elf", "--stdio", "fw.elf" };
    try std.testing.expect(cli.parseWithCatalog(absent, &list) == null);
    const dual_line = &.{ "ra8", "serve", "--device", "ra8d2", "--cpu1", "c.elf", "--stdio", "fw.elf" };
    const dual = cli.parseWithCatalog(dual_line, &list).?;
    try std.testing.expectEqualStrings("c.elf", dual.cpu1.?);
    const shipped_only = &.{ "ra8", "serve", "--part", "ra8p1", "--stdio", "fw.elf" };
    try std.testing.expect(cli.parseWithCatalog(shipped_only, &list) == null);
    const shipped = cli.parse(&.{ "ra8", "serve", "--part", "ra8p1", "--stdio", "fw.elf" }).?;
    try std.testing.expectEqual(&machine_mod.catalog.ra8p1, shipped.machine.?);
}
