const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");

const model = ra8.host.targets;
const probe_agent = cli.probe_agent;
const wire = ra8.host.probe_host.wire;

fn noop(_: *anyopaque, _: model.Action, _: []u8) ![]const u8 {
    return "{\"ok\":true}";
}

test "probe-agent CLI rejects unix sockets missing flags and competing or stale claims" {
    const ok = try probe_agent.parse(&.{
        "emu",           "probe-agent",
        "--targets",     "t.json",
        "--secret-file", "s.key",
        "--host-id",     "bench-a",
        "--listen",      "tcp:127.0.0.1:0",
    });
    try std.testing.expectEqualStrings("bench-a", ok.host_id);
    try std.testing.expectError(error.BadArguments, probe_agent.parse(&.{
        "emu",           "probe-agent",
        "--targets",     "t.json",
        "--secret-file", "s.key",
        "--host-id",     "bench-a",
        "--listen",      "unix:/tmp/a.sock",
    }));

    var registry: model.Registry = .{};
    var dummy: u8 = 0;
    _ = try registry.add(.{
        .host_id = "bench-a",
        .probe_id = "probe-a",
        .board_id = "board-a",
        .transport = "jlink-usb",
        .connection = .connected,
        .identity_verified = true,
        .managed = false,
        .operations = &.{.registers},
        .capabilities = .{ .hardware_debug = true },
    }, .{ .context = &dummy, .performFn = noop });

    var state: probe_agent.State = .{ .io = std.testing.io, .host_id = "bench-a", .registry = &registry };
    var one: probe_agent.Peer = .{};
    var two: probe_agent.Peer = .{};
    var snaps: [32]wire.Snapshot = undefined;
    var out: [256]u8 = undefined;

    const listed = try probe_agent.dispatch(&state, &one, .{ .op = .list }, &snaps, &out);
    try std.testing.expectEqual(@as(usize, 1), listed.targets.len);
    const c1 = try probe_agent.dispatch(&state, &one, .{
        .op = .claim,
        .probe_id = "probe-a",
        .board_id = "board-a",
    }, &snaps, &out);
    try std.testing.expectEqual(@as(u64, 1), c1.token);
    try std.testing.expectError(error.TargetBusy, probe_agent.dispatch(&state, &two, .{
        .op = .claim,
        .probe_id = "probe-a",
        .board_id = "board-a",
    }, &snaps, &out));
    _ = try probe_agent.dispatch(&state, &one, .{ .op = .release, .token = c1.token }, &snaps, &out);
    const c2 = try probe_agent.dispatch(&state, &two, .{
        .op = .claim,
        .probe_id = "probe-a",
        .board_id = "board-a",
    }, &snaps, &out);
    try std.testing.expectEqual(@as(u64, 2), c2.token);
    try std.testing.expectError(error.StaleLease, probe_agent.dispatch(&state, &one, .{
        .op = .perform,
        .probe_id = "probe-a",
        .board_id = "board-a",
        .token = c1.token,
        .action = .registers,
    }, &snaps, &out));
}
