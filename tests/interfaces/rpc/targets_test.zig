const std = @import("std");

const fixture = @import("../../host/targets_test.zig");
const ra8 = @import("ra8");
const wire = ra8.rpc.targets_wire;
const served = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;

// Exercise the public framed server, including connection cleanup and codec bounds.
test "target RPC frames list reserve operate and release only their own connection" {
    var registry: ra8.host.targets.Registry = .{};
    var a: fixture.Log = .{};
    var b: fixture.Log = .{};
    const gen = try registry.add(fixture.descriptor("board", "probe"), a.provider());
    _ = try registry.add(fixture.descriptor("other", "other"), b.provider());
    var scratch: [32768]u8 = undefined;
    var context: served.Context = .{ .session = undefined, .scratch = &scratch, .targets = &registry };
    var other: served.Context = .{ .session = undefined, .scratch = &scratch, .targets = &registry };
    var buffers: [5][70000]u8 = undefined;
    var loop = served.rpc_lib.Loopback.init(&buffers[0], &buffers[1]);
    var client = proto.Client.init(loop.a(), &buffers[2], proto.capabilities | wire.capability);
    var server = served.Server.init(loop.b(), &buffers[3], &context, proto.capabilities | wire.capability);
    const tx = &buffers[4];
    try client.greet(tx);
    try std.testing.expectEqual(served.rpc_lib.Step.greeted, try server.poll(tx));
    _ = (try client.poll(tx)).?;
    _ = try client.call(struct {}, @backingInt(wire.Method.list), .{}, 0, tx);
    try std.testing.expectEqual(served.rpc_lib.Step.answered, try server.poll(tx));
    const listing = try proto.decode(wire.Text, (try client.poll(tx)).?.response.result.ok);
    try std.testing.expect(std.mem.indexOf(u8, listing.json, "board") != null);
    const selected: wire.Selection = .{ .host_id = "fixture-host", .probe_id = "probe", .board_id = "board", .generation = gen, .disambiguation = "" };
    _ = try client.call(wire.Selection, @backingInt(wire.Method.reserve), selected, 0, tx);
    try std.testing.expectEqual(served.rpc_lib.Step.answered, try server.poll(tx));
    _ = (try client.poll(tx)).?.response.result.ok;
    try std.testing.expectEqual(wire.codes.busy, @backingInt(ra8.rpc.targets.reserve(&other, selected).err));
    try std.testing.expectEqual(wire.codes.ownership, @backingInt(ra8.rpc.targets.perform(&other, wire.operation(selected, .halt)).err));
    _ = try client.call(wire.Perform, @backingInt(wire.Method.perform), wire.operation(selected, .halt), 0, tx);
    try std.testing.expectEqual(served.rpc_lib.Step.answered, try server.poll(tx));
    const performed = try proto.decode(wire.Text, (try client.poll(tx)).?.response.result.ok);
    try std.testing.expectEqualStrings("{\"ok\":true}", performed.json);
    try std.testing.expectEqual(@as(usize, 1), a.calls);
    try std.testing.expectEqual(@as(usize, 0), b.calls);
    served.forget(&context);
    try std.testing.expectEqual(@as(u8, 1), ra8.rpc.targets.reserve(&other, selected).ok.accepted);
    served.forget(&other);
    try std.testing.expect(registry.entries[0].?.owner == null);
}

test "a full inventory lists bounded metadata even when JSON escaping expands it" {
    const gpa = std.testing.allocator;
    var registry: ra8.host.targets.Registry = .{};
    var log: fixture.Log = .{};
    var boards: [32][32]u8 = undefined;
    var probes: [32][32]u8 = undefined;
    const metadata: [128]u8 = @splat(0);
    for (&boards, &probes, 0..) |*board, *probe, index| {
        var target = fixture.descriptor(
            try std.fmt.bufPrint(board, "board-{d}", .{index}),
            try std.fmt.bufPrint(probe, "probe-{d}", .{index}),
        );
        target.probe_serial = &metadata;
        target.board_serial = &metadata;
        target.vendor = &metadata;
        target.model = &metadata;
        target.cores = &metadata;
        target.disambiguation = &metadata;
        _ = try registry.add(target, log.provider());
    }
    const scratch = try gpa.alloc(u8, wire.max_json);
    defer gpa.free(scratch);
    var context: served.Context = .{ .session = undefined, .scratch = scratch, .targets = &registry };
    const result = ra8.rpc.targets.list(&context, .{});
    try std.testing.expect(result == .ok);
    try std.testing.expect(result.ok.json.len > 32768);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, result.ok.json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 32), parsed.value.array.items.len);
}

const RpcFlashProvider = struct {
    flashed: usize = 0,
    resets: usize = 0,
    fn perform(ctx: *anyopaque, action: ra8.host.targets.Action, _: []u8) ![]const u8 {
        const self: *RpcFlashProvider = @ptrCast(@alignCast(ctx));
        if (action == .reset) {
            self.resets += 1;
            return "{\"reset\":true}";
        }
        return "{\"ok\":true}";
    }
    fn flash(ctx: *anyopaque, elf: []const u8, out: []u8) ![]const u8 {
        const self: *RpcFlashProvider = @ptrCast(@alignCast(ctx));
        self.flashed += 1;
        return std.fmt.bufPrint(out, "{{\"flashed\":true,\"bytes\":{d}}}", .{elf.len});
    }
};

test "target RPC streams chunked ELF flash reset and emits progress events on topic 0x183" {
    const gpa = std.testing.allocator;
    var registry: ra8.host.targets.Registry = .{};
    var prov: RpcFlashProvider = .{};
    var desc = fixture.descriptor("fpb-ra8e1", "jlink-a");
    desc.operations = &.{ .registers, .flash, .reset };
    desc.capabilities = .{ .hardware_debug = true, .flash = true };
    const gen = try registry.add(desc, .{
        .context = &prov,
        .performFn = RpcFlashProvider.perform,
        .flashFn = RpcFlashProvider.flash,
    });

    var scratch: [32768]u8 = undefined;
    var context: served.Context = .{
        .session = undefined,
        .scratch = &scratch,
        .targets = &registry,
        .gpa = gpa,
    };
    defer served.forget(&context);

    const sel: wire.Selection = .{
        .host_id = "fixture-host",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .generation = gen,
        .disambiguation = "",
    };
    try std.testing.expectEqual(@as(u8, 1), ra8.rpc.targets.reserve(&context, sel).ok.accepted);
    const image = "synthetic-elf-payload";
    try std.testing.expectEqual(@as(u8, 1), ra8.rpc.targets.flashBegin(&context, .{
        .total_len = image.len,
        .checksum = std.hash.Crc32.hash(image),
    }).ok.accepted);
    try std.testing.expectEqual(@as(u8, 1), ra8.rpc.targets.flashChunk(&context, .{
        .offset = 0,
        .bytes = image,
    }).ok.accepted);
    const committed = ra8.rpc.targets.flashCommit(&context, .{
        .host_id = sel.host_id,
        .probe_id = sel.probe_id,
        .board_id = sel.board_id,
        .generation = sel.generation,
        .disambiguation = sel.disambiguation,
        .reset = 1,
        .uart = 0,
    });
    try std.testing.expect(committed == .ok);
    try std.testing.expect(std.mem.indexOf(u8, committed.ok.json, "\"flashed\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, committed.ok.json, "\"reset\":{\"reset\":true}") != null);
    try std.testing.expectEqual(@as(usize, 1), prov.flashed);
    try std.testing.expectEqual(@as(usize, 1), prov.resets);
    try std.testing.expectEqual(@as(usize, 2), context.target_flash.progress.count);
}
