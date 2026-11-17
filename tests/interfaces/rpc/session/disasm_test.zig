//! A real RPC route serves the exact annotation transcript to remote panes.
const std = @import("std");

const api = @import("ra8").session.api;
const fixture = @import("../../../session/annotation_fixture.zig");
const proto = @import("ra8").rpc.session.rpc;
const ra8 = @import("ra8");
const served = ra8.rpc.session.server;

const rpc = served.rpc_lib;
const Env = proto.Client.Env;

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoMap;
}

fn imageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const image: *ra8.session.symbols.Image = @ptrCast(@alignCast(context));
    return if (core == 0) image.* else null;
}

test "pane disassembly wire preserves names locals constant and range refusals" {
    var image_buffer: [2048]u8 = undefined;
    var image = try fixture.image(&image_buffer);
    var memory = fixture.Ram.init();
    var cpu: ra8.chip.core.cpu.cpu.Cpu = .{ .bus = memory.view() };
    var machine: ra8.session.stop_machine.Machine = .{};
    var session: api.Session = .{ .live = .{ .core = .{ .cpu = &cpu }, .machine = &machine, .budget = 100 } };
    var scratch: [32_768]u8 = undefined;
    var context: served.Context = .{
        .session = &session,
        .scratch = &scratch,
        .mapping = .{ .context = &image, .mapFn = noMap, .imageFn = imageOf },
    };
    const buffers = try std.testing.allocator.alloc(u8, Env.max_frame * 5);
    defer std.testing.allocator.free(buffers);
    var loop = rpc.Loopback.init(buffers[0..Env.max_frame], buffers[Env.max_frame .. 2 * Env.max_frame]);
    var client = proto.Client.init(loop.a(), buffers[2 * Env.max_frame .. 3 * Env.max_frame], proto.capabilities);
    var host = served.Host.init(loop.b(), buffers[3 * Env.max_frame .. 4 * Env.max_frame], &context);
    const tx = buffers[4 * Env.max_frame ..];
    try client.greet(tx);
    try std.testing.expectEqual(rpc.Step.greeted, try host.poll(tx));
    const ready = (try client.poll(tx)).?.ready;
    try std.testing.expect(ready & (1 << 22) != 0);
    _ = try client.call(proto.Disassemble, @backingInt(proto.Method.disassemble), .{ .core = .cpu0, .address = 0x100, .count = 4 }, 0, tx);
    try std.testing.expectEqual(rpc.Step.answered, try host.poll(tx));
    const result = (try client.poll(tx)).?.response.result;
    const reply = try proto.decode(proto.Disassembly, result.ok);
    try std.testing.expectEqualStrings(fixture.golden, reply.text);
    try std.testing.expectEqual(@as(u32, 0x10c), reply.next);
    for ([_]proto.Disassemble{
        .{ .core = .cpu0, .address = 0x101, .count = 1 },
        .{ .core = .cpu0, .address = 0x100, .count = 0 },
        .{ .core = .cpu0, .address = 0x100, .count = 65 },
        .{ .core = .cpu1, .address = 0x100, .count = 1 },
    }) |asked| {
        _ = try client.call(proto.Disassemble, @backingInt(proto.Method.disassemble), asked, 0, tx);
        _ = try host.poll(tx);
        try std.testing.expect((try client.poll(tx)).?.response.result == .err);
    }
}
