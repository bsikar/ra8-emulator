//! Covers src/session/history/action_codec.zig: every intervention family
//! decodes back to the action it logged, with the core, the endpoint, the
//! fault mode and the input's virtual time it was aimed with.
const std = @import("std");
const ra8 = @import("ra8");

const codec = ra8.session.history_action_codec;
const router = ra8.session.history_fork_router;

const Action = router.Action;

fn roundTrip(action: Action) !Action {
    const gpa = std.testing.allocator;
    var encoded = try codec.encode(gpa, action);
    defer codec.free(gpa, &encoded);
    return codec.decode(gpa, encoded.what, encoded.body);
}

test "a register write keeps its core" {
    const back = try roundTrip(.{ .register = .{ .core = .cpu1, .which = .r3, .value = 0xDEADBEEF } });
    try std.testing.expectEqual(ra8.session.api.Core.cpu1, back.register.core);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), back.register.value);
}

test "a memory write keeps its core, address and bytes" {
    var back = try roundTrip(.{ .memory = .{ .core = .cpu1, .address = 0x2000_0100, .bytes = "abc" } });
    defer router.freeAction(std.testing.allocator, &back);
    try std.testing.expectEqual(ra8.session.api.Core.cpu1, back.memory.core);
    try std.testing.expectEqual(@as(u32, 0x2000_0100), back.memory.address);
    try std.testing.expectEqualStrings("abc", back.memory.bytes);
}

test "a scheduled input keeps the time it was scheduled for" {
    const back = try roundTrip(.{ .input = .{ .core = .cpu1, .at_ns = 123_456_789, .event = .{ .tap = .{ .x = 7, .y = 9 } } } });
    try std.testing.expectEqual(@as(u64, 123_456_789), back.input.at_ns);
    try std.testing.expectEqual(ra8.session.api.Core.cpu1, back.input.core);
    try std.testing.expectEqual(@as(u16, 9), back.input.event.tap.y);
}

test "plug and unplug keep the endpoint and the part's name" {
    const at: router.Endpoint = .{ .i2c = .{ .line = .touch, .address = 0x38 } };
    var plugged = try roundTrip(.{ .plug = .{ .core = .cpu1, .at = at, .name = "gt911" } });
    defer router.freeAction(std.testing.allocator, &plugged);
    try std.testing.expect(std.meta.eql(at, plugged.plug.at));
    try std.testing.expectEqualStrings("gt911", plugged.plug.name.?);
    try std.testing.expectEqual(ra8.session.api.Core.cpu1, plugged.plug.core);

    const gone = try roundTrip(.{ .plug = .{ .core = .cpu0, .at = at, .name = null } });
    try std.testing.expect(gone.plug.name == null);
    try std.testing.expect(std.meta.eql(at, gone.plug.at));
}

test "a fault keeps its endpoint and every mode, and a clear has none" {
    const at: router.Endpoint = .{ .uart = .{ .channel = 4 } };
    const modes = [_]router.FaultMode{
        .disconnected,      .bus_low,              .{ .nack_every = 3 },     .{ .stuck = 0xA5 },
        .{ .garbage = 77 }, .{ .slow_ns = 1_000 }, .{ .stretch_ns = 2_000 },
    };
    for (modes) |mode| {
        const back = try roundTrip(.{ .fault = .{ .core = .cpu1, .at = at, .mode = mode } });
        try std.testing.expect(std.meta.eql(mode, back.fault.mode.?));
        try std.testing.expect(std.meta.eql(at, back.fault.at));
        try std.testing.expectEqual(ra8.session.api.Core.cpu1, back.fault.core);
    }
    const cleared = try roundTrip(.{ .fault = .{ .core = .cpu0, .at = at, .mode = null } });
    try std.testing.expect(cleared.fault.mode == null);
}

test "skip bkpt, console, camera and load round trip" {
    const gpa = std.testing.allocator;
    const skip = try roundTrip(.{ .skip_bkpt = .{ .core = .cpu1 } });
    try std.testing.expectEqual(ra8.session.api.Core.cpu1, skip.skip_bkpt.core);
    var console = try roundTrip(.{ .console = .{ .core = .cpu0, .bytes = "ls\r" } });
    defer router.freeAction(gpa, &console);
    try std.testing.expectEqualStrings("ls\r", console.console.bytes);
    var camera = try roundTrip(.{ .camera = .{ .core = .cpu0, .spec = "file:a.png" } });
    defer router.freeAction(gpa, &camera);
    try std.testing.expectEqualStrings("file:a.png", camera.camera.spec);
    var load = try roundTrip(.{ .load = .{ .core = .cpu1, .image = "IMG" } });
    defer router.freeAction(gpa, &load);
    try std.testing.expectEqual(ra8.session.api.Core.cpu1, load.load.core);
    try std.testing.expectEqualStrings("IMG", load.load.image);
}

test "a truncated or malformed body is an error, not a skip" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Truncated, codec.decode(gpa, .register_write, &.{ 0, 1 }));
    try std.testing.expectError(error.BadValue, codec.decode(gpa, .skip_bkpt, &.{9}));
    try std.testing.expectError(error.BadValue, codec.decode(gpa, .fault, &.{ 0, 3, 'x', 'y', 'z' }));
    try std.testing.expectError(error.BadValue, codec.decode(gpa, .rpc_mutation, ""));
}
