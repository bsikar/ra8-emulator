//! Tests for src/interfaces/rpc/session/source_line.zig (RA8EMU-1125) on
//! the uart_irq_echo fixture, the one image with .debug_line: a core
//! stopped inside ra8_sci_init answers its pc's file and line, a server
//! holding no image answers found=0, and a core with no image loaded is
//! refused; the report round-trips through the wire.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const handler = ra8.rpc.session.source_line;

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
/// ra8_sci_init's first instruction (its symbol is 0x02001975).
const sci_init: u32 = 0x0200_1974;

fn imageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    return harness.loadedImage(if (core == 0) .cpu0 else .cpu1);
}

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoImage;
}

/// The fixture stopped on ra8_sci_init's first instruction.
fn stopped() !ra8.session.harness.Harness {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    errdefer opened.deinit();
    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);
    try std.testing.expectEqual(sci_init, try session.register(.cpu0, .pc));
    return opened;
}

/// Ask for `core`'s source place; `named` hands the server the loaded image.
fn ask(opened: *ra8.session.harness.Harness, scratch: []u8, core: proto.Core, named: bool) !proto.SourceLine {
    var context: server.Context = .{ .session = opened.session(), .scratch = scratch };
    if (named) context.mapping = .{ .context = opened, .mapFn = noMap, .imageFn = imageOf };
    return switch (handler.sourceLine(&context, .{ .core = core })) {
        .ok => |found| found,
        .err => error.Refused,
    };
}

test "a stop inside ra8_sci_init answers its file and line" {
    var opened = try stopped();
    defer opened.deinit();
    var scratch: [proto.source_path_cap]u8 = undefined;
    const place = try ask(&opened, &scratch, .cpu0, true);
    try std.testing.expectEqual(@as(u8, 1), place.found);
    try std.testing.expectEqual(sci_init, place.pc);
    try std.testing.expectEqual(@as(u32, 253), place.line);
    try std.testing.expect(std.mem.endsWith(u8, place.path, "ra8_sci.c"));
}

test "a server holding no image answers found=0" {
    var opened = try stopped();
    defer opened.deinit();
    var scratch: [proto.source_path_cap]u8 = undefined;
    const bare = try ask(&opened, &scratch, .cpu0, false);
    try std.testing.expectEqual(@as(u8, 0), bare.found);
    try std.testing.expectEqual(@as(u32, 0), bare.pc);
    try std.testing.expectEqual(@as(u32, 0), bare.line);
    try std.testing.expectEqual(@as(usize, 0), bare.path.len);
}

test "a core with no image loaded is refused" {
    var opened = try stopped();
    defer opened.deinit();
    var scratch: [proto.source_path_cap]u8 = undefined;
    try std.testing.expectError(error.Refused, ask(&opened, &scratch, .cpu1, true));
}

test "the report round-trips through the wire" {
    const value: proto.SourceLine = .{ .found = 1, .pc = 0x0200_1974, .line = 253, .path = "ra8_sci.c" };
    var bytes: [proto.max_payload]u8 = undefined;
    const encoded = try proto.encode(proto.SourceLine, value, &bytes);
    const decoded = try proto.decode(proto.SourceLine, encoded);
    try std.testing.expectEqualDeep(value, decoded);
}
