//! RPC disassembly route tests for both annotated (`disassemble`) and packed (`disasm`) ops.
const std = @import("std");

const fixture = @import("../../../session/annotation_fixture.zig");
const ra8 = @import("ra8");

const api = ra8.session.api;
const disasm_wire = ra8.rpc.session.disasm_wire;
const handler = ra8.rpc.session.disasm;
const proto = ra8.rpc.session.rpc;
const served = ra8.rpc.session.server;

const Env = proto.Client.Env;
const rpc = served.rpc_lib;

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
const sci_init: u32 = 0x0200_1974;

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoMap;
}

fn fixtureImageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const image: *ra8.session.symbols.Image = @ptrCast(@alignCast(context));
    return if (core == 0) image.* else null;
}

fn harnessImageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    return harness.loadedImage(if (core == 0) .cpu0 else .cpu1);
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
        .mapping = .{ .context = &image, .mapFn = noMap, .imageFn = fixtureImageOf },
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
    const ask: proto.Disassemble = .{ .core = .cpu0, .address = 0x100, .count = 4 };
    _ = try client.call(proto.Disassemble, @backingInt(proto.Method.disassemble), ask, 0, tx);
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

test "Method opcode disasm is 0x012F and routed in server" {
    try std.testing.expectEqual(@as(u16, 0x012F), @backingInt(proto.Method.disasm));
    var found = false;
    inline for (served.routes) |route| {
        if (route[0] == @backingInt(proto.Method.disasm)) found = true;
    }
    try std.testing.expect(found);
}

test "disasm decodes instructions forward from PC with symbol entry label" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = image_path,
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();

    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);

    var scratch: [disasm_wire.disasm_bytes]u8 = undefined;
    var context: served.Context = .{
        .session = session,
        .scratch = &scratch,
        .mapping = .{ .context = &opened, .mapFn = noMap, .imageFn = harnessImageOf },
    };

    const reply = switch (handler.disasm(&context, .{ .core = .cpu0, .count = 8, .use_pc = 1 })) {
        .ok => |r| r,
        .err => return error.Refused,
    };

    try std.testing.expectEqual(proto.Core.cpu0, reply.core);
    try std.testing.expectEqual(sci_init, reply.pc);
    try std.testing.expectEqual(@as(u8, 8), reply.count);

    var reader: disasm_wire.Reader = .{ .rest = reply.rows };
    const first = (try reader.next()).?;
    try std.testing.expectEqual(sci_init, first.address);
    try std.testing.expectEqual(@as(u8, 1), first.decoded);
    try std.testing.expect(first.text.len > 0);
    try std.testing.expectEqualStrings("ra8_sci_init", first.symbol);
}

test "disasm refuses unattached CPU1 with no_core" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = image_path,
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();

    var scratch: [disasm_wire.disasm_bytes]u8 = undefined;
    var context: served.Context = .{ .session = opened.session(), .scratch = &scratch };
    switch (handler.disasm(&context, .{ .core = .cpu1, .count = 4, .use_pc = 1 })) {
        .ok => return error.ExpectedRefusal,
        .err => |code| try std.testing.expectEqual(@as(u16, proto.app_codes.no_core), @backingInt(code)),
    }
}
