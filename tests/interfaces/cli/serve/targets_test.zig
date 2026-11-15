const std = @import("std");

const cli = @import("cli_app");

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
    var session: @import("ra8").session.api.Session = undefined;
    try inventory.open(std.testing.allocator, std.testing.io, path, &session);
    const caps = inventory.registry.entries[0].?.target.capabilities;
    try std.testing.expect(caps.hardware_debug);
    try std.testing.expect(!caps.flash and !caps.build and !caps.npu and !caps.emulation);
}
