const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");

const agent_link = cli.serve.agent_link;
const auth = ra8.host.probe_host.auth;
const profiles = ra8.host.profiles;
const wire = ra8.host.probe_host.wire;

test "agentArgv formats local and ssh probe-agent commands with shell-safe quoting" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const local_argv = try agent_link.agentArgv(gpa, std.testing.io, .{
        .profile = profiles.Profile.local,
        .remote_targets = "/etc/ra8/targets.json",
        .remote_secret_file = "/etc/ra8/secret.key",
        .local_emulator = "/opt/ra8/ra8_emulator",
    }, "bench-local");
    try std.testing.expectEqual(@as(usize, 9), local_argv.len);
    try std.testing.expectEqualStrings("/opt/ra8/ra8_emulator", local_argv[0]);
    try std.testing.expectEqualStrings("probe-agent", local_argv[1]);
    try std.testing.expectEqualStrings("--stdio", local_argv[8]);

    const ssh_argv = try agent_link.agentArgv(gpa, std.testing.io, .{
        .profile = profiles.Profile{ .ssh = .{
            .destination = "bench@laptop",
            .emulator = "/opt/ra8 dir/ra8_emulator",
            .program = "ssh",
        } },
        .remote_targets = "/home/bench/my 'targets'.json",
        .remote_secret_file = "/home/bench/secret.key",
    }, "laptop-bench");
    try std.testing.expectEqual(@as(usize, 4), ssh_argv.len);
    try std.testing.expectEqualStrings("ssh", ssh_argv[0]);
    try std.testing.expectEqualStrings("-T", ssh_argv[1]);
    try std.testing.expectEqualStrings("bench@laptop", ssh_argv[2]);
    try std.testing.expect(std.mem.indexOf(u8, ssh_argv[3], "'/opt/ra8 dir/ra8_emulator' probe-agent") != null);
    try std.testing.expect(std.mem.indexOf(u8, ssh_argv[3], "'/home/bench/my '\\''targets'\\''.json'") != null);
    try std.testing.expect(std.mem.endsWith(u8, ssh_argv[3], "--stdio"));
}

test "agent_link spawns probe-agent --stdio over a local profile and authenticates per-frame RPC" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const hex_key = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.key", .data = hex_key });
    try tmp.dir.writeFile(io, .{ .sub_path = "targets.json", .data = "[]" });
    const secret_path = try tmp.dir.realPathFileAlloc(io, "secret.key", gpa);
    defer gpa.free(secret_path);
    const targets_path = try tmp.dir.realPathFileAlloc(io, "targets.json", gpa);
    defer gpa.free(targets_path);
    const key = try auth.readKey(io, secret_path);

    var link: agent_link.Link = .closed;
    defer link.close(io);
    try link.connect(io, .{ .profile = .{
        .profile = .local,
        .remote_targets = targets_path,
        .remote_secret_file = secret_path,
        .local_emulator = test_paths.emulator,
    } }, "stdio-bench", key);
    try std.testing.expect(link.isOpen());

    try link.send(io, .{ .op = .list });
    var scratch: [wire.max_line]u8 = undefined;
    const reply = try link.receive(gpa, io, &scratch, 5_000);
    defer reply.deinit();
    try std.testing.expect(reply.value.ok);
    try std.testing.expectEqual(@as(usize, 0), reply.value.targets.len);
}
