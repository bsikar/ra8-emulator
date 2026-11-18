const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");

const elf_image = ra8.host.jlink.elf_image;
const model = ra8.host.targets;
const probe_agent = cli.probe_agent;
const probe_dispatch = cli.probe_dispatch;
const wire = ra8.host.probe_host.wire;

const DummyFlash = struct {
    seen_len: usize = 0,
    fn perform(_: *anyopaque, _: model.Action, _: []u8) ![]const u8 {
        return "{\"ok\":true}";
    }
    fn flash(ctx: *anyopaque, elf: []const u8, out: []u8) ![]const u8 {
        const self: *DummyFlash = @ptrCast(@alignCast(ctx));
        self.seen_len = elf.len;
        return std.fmt.bufPrint(out, "{{\"flashed\":true,\"bytes\":{d}}}", .{elf.len});
    }
};

test "probe_dispatch executes chunked flash commit only for active lease owner" {
    var registry: model.Registry = .{};
    var dummy: DummyFlash = .{};
    _ = try registry.add(.{
        .host_id = "bench-a",
        .probe_id = "probe-a",
        .board_id = "board-a",
        .transport = "jlink-usb",
        .connection = .connected,
        .identity_verified = true,
        .managed = false,
        .operations = &.{ .registers, .flash },
        .capabilities = .{ .hardware_debug = true, .flash = true },
    }, .{ .context = &dummy, .performFn = DummyFlash.perform, .flashFn = DummyFlash.flash });

    var state: probe_agent.State = .{ .io = std.testing.io, .host_id = "bench-a", .registry = &registry };
    var peer: probe_agent.Peer = .{};
    defer peer.stage.drop();
    var snaps: [32]wire.Snapshot = undefined;
    var out: [256]u8 = undefined;

    const claimed = try probe_dispatch.execute(&state, &peer, .{
        .op = .claim,
        .probe_id = "probe-a",
        .board_id = "board-a",
    }, &snaps, &out);
    const payload = "test-elf-payload";
    const sha = elf_image.sha256Hex(payload);
    const hex = std.fmt.bytesToHex(payload, .lower);

    _ = try probe_dispatch.execute(&state, &peer, .{
        .op = .flash_begin,
        .token = claimed.token,
        .total_len = payload.len,
        .sha256 = &sha,
    }, &snaps, &out);
    _ = try probe_dispatch.execute(&state, &peer, .{
        .op = .flash_chunk,
        .token = claimed.token,
        .offset = 0,
        .hex = &hex,
    }, &snaps, &out);
    const committed = try probe_dispatch.execute(&state, &peer, .{
        .op = .flash_commit,
        .probe_id = "probe-a",
        .board_id = "board-a",
        .token = claimed.token,
    }, &snaps, &out);
    try std.testing.expectEqual(@as(usize, payload.len), dummy.seen_len);
    try std.testing.expect(std.mem.indexOf(u8, committed.json, "\"flashed\":true") != null);
}
