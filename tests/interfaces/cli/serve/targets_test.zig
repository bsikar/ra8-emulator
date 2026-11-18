const builtin = @import("builtin");
const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");

test "target bindings require explicit opt in and cannot survive artifact replacement" {
    try std.testing.expect(cli.serve.main.parse(&.{ "emu", "serve", "--stdio", "fw.elf" }).?.targets == null);
    const args = &.{ "emu", "serve", "--targets", "bindings.json", "--stdio", "fw.elf" };
    try std.testing.expectEqualStrings("bindings.json", cli.serve.main.parse(args).?.targets.?);
    const both = &.{ "emu", "serve", "--targets", "bindings.json", "--artifacts-root", ".", "--stdio", "fw.elf" };
    try std.testing.expect(cli.serve.main.parse(both) == null);
}

test "operator bindings cannot advertise unimplemented flash build or NPU capabilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "[{\"kind\":\"rsp\",\"host\":\"127.0.0.1\",\"port\":1234,\"target\":{" ++
        "\"managed\":false,\"host_id\":\"host\",\"board_id\":\"board\",\"probe_id\":\"probe\",\"transport\":\"rsp\"," ++
        "\"capabilities\":{\"flash\":true,\"build\":true,\"npu\":true}}}]";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bindings.json", .data = text });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "bindings.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var inventory: cli.target_bindings.Inventory = .{};
    defer inventory.close();
    var session: ra8.session.api.Session = undefined;
    try inventory.open(std.testing.allocator, std.testing.io, path, &session);
    const caps = inventory.registry.entries[0].?.target.capabilities;
    try std.testing.expect(caps.hardware_debug);
    try std.testing.expect(!caps.flash and !caps.build and !caps.npu and !caps.emulation);
}

test "jlink and agent bindings require pinned serials absolute paths and unique endpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const dup_serial =
        "[{\"kind\":\"jlink\",\"program\":\"JLink\",\"scratch\":\"" ++
        (if (builtin.os.tag == .windows) "C:\\\\tmp" else "/tmp") ++
        "\",\"device\":\"Cortex-M85\",\"cpuid\":\"0x410FD232\",\"target\":{" ++
        "\"managed\":false,\"host_id\":\"h\",\"board_id\":\"b1\",\"probe_id\":\"p1\"," ++
        "\"probe_serial\":\"001083322193\",\"transport\":\"jlink-usb\"}}," ++
        "{\"kind\":\"jlink\",\"program\":\"JLink\",\"scratch\":\"" ++
        (if (builtin.os.tag == .windows) "C:\\\\tmp" else "/tmp") ++
        "\",\"device\":\"Cortex-M33\",\"cpuid\":\"0x410FD214\",\"target\":{" ++
        "\"managed\":false,\"host_id\":\"h\",\"board_id\":\"b2\",\"probe_id\":\"p2\"," ++
        "\"probe_serial\":\"1083322193\",\"transport\":\"jlink-usb\"}}]";
    try tmp.dir.writeFile(io, .{ .sub_path = "dup.json", .data = dup_serial });
    const dup_path = try tmp.dir.realPathFileAlloc(io, "dup.json", alloc);
    defer alloc.free(dup_path);
    var inventory: cli.target_bindings.Inventory = .{};
    defer inventory.close();
    try std.testing.expectError(error.DuplicateIdentity, inventory.open(alloc, io, dup_path, null));
}
