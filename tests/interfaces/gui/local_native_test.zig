//! Tests for src/interfaces/gui/local_native.zig (slice 15): the local GUI's
//! typed requests dispatch straight to the served handlers, and the feeds'
//! events arrive on the link's queue with no RPC framing between the shell
//! and the session it owns in-process.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const local_native = gui_app.local_native;
const served_setup = ra8.rpc.served_setup;
const proto = ra8.rpc.session.rpc;

const image = "tests/fixtures/fpu/fp_basic.elf";

fn opened(gpa: std.mem.Allocator) !served_setup.Served {
    var setup: served_setup.Served = undefined;
    try setup.open(gpa, std.testing.io, image, null);
    return setup;
}

test "a typed request answers through the native link" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var link = local_native.Link.init(gpa, &setup.context);
    defer link.deinit();

    const id = try link.send(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    const arrival = (try link.pump()).?;
    try std.testing.expectEqualStrings("response", @tagName(arrival));
    try std.testing.expectEqual(id, arrival.response.id);
    const reply = try proto.decode(proto.U32, arrival.response.result.ok);
    try std.testing.expect(reply.value != 0);
    try std.testing.expect((try link.pump()) == null);
}

test "a queue at the client's pending-table cap refuses more sends" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var link = local_native.Link.init(gpa, &setup.context);
    defer link.deinit();

    var sent: usize = 0;
    while (sent < proto.pending_slots) : (sent += 1) {
        _ = try link.send(proto.Now, .now, .{ .core = .cpu0 });
    }
    try std.testing.expectError(error.TableFull, link.send(proto.Now, .now, .{ .core = .cpu0 }));
    // The answers drain one arrival per pump, oldest first, and the
    // back-pressure lifts as they do.
    var taken: usize = 0;
    while ((try link.pump())) |arrival| {
        try std.testing.expectEqualStrings("response", @tagName(arrival));
        taken += 1;
        if (taken == proto.pending_slots) break;
    }
    _ = try link.send(proto.Now, .now, .{ .core = .cpu0 });
}

test "the session's stop lands on the link's event queue" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var link = local_native.Link.init(gpa, &setup.context);
    defer link.deinit();

    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    const ack = (try link.pump()).?;
    try std.testing.expectEqualStrings("response", @tagName(ack));

    _ = try link.send(proto.CoreOnly, .step, .{ .core = .cpu0 });
    var stop_seen = false;
    while (!stop_seen) {
        const arrival = (try link.pump()) orelse break;
        if (arrival == .event and arrival.event.topic == @backingInt(proto.Topic.stop)) {
            const stopped = try proto.decode(proto.Stopped, arrival.event.payload);
            try std.testing.expectEqual(proto.Core.cpu0, stopped.core);
            stop_seen = true;
        }
    }
    try std.testing.expect(stop_seen);
}
