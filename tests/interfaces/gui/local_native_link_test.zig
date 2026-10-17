//! Tests for src/interfaces/gui/local_native_link.zig (slice 15): the
//! shell's native link queues typed requests for the session's thread,
//! which dispatches them to the handlers and queues the arrivals the
//! window takes. The answers are the ones the wire link gives, with no
//! bytes between the two sides.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");

const local_native_link = gui_app.local_native_link;
const session_link = gui_app.session_link;
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
    var host = gui_app.wall_clock.Host.init(std.testing.io);
    const clock = host.clock();
    var native = local_native_link.Native.init(std.testing.io, gpa, clock, &setup.context);
    defer native.deinit();
    var link: session_link.Link = undefined;
    link.openNative(&native);

    const id = try link.send(proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    _ = try native.serve();
    const arrival = link.pump().?;
    try std.testing.expectEqualStrings("response", @tagName(arrival));
    try std.testing.expectEqual(id, arrival.response.id);
    const reply = try proto.decode(proto.U32, arrival.response.result.ok);
    try std.testing.expect(reply.value != 0);
    try std.testing.expect((link.pump()) == null);
}

test "a full mailbox refuses more sends until the session drains it" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var host = gui_app.wall_clock.Host.init(std.testing.io);
    const clock = host.clock();
    var native = local_native_link.Native.init(std.testing.io, gpa, clock, &setup.context);
    defer native.deinit();
    var link: session_link.Link = undefined;
    link.openNative(&native);

    var sent: usize = 0;
    while (sent < local_native_link.max_requests) : (sent += 1) {
        _ = try link.send(proto.Now, .now, .{ .core = .cpu0 });
    }
    try std.testing.expectError(error.TableFull, link.send(proto.Now, .now, .{ .core = .cpu0 }));
    _ = try native.serve();
    var taken: usize = 0;
    while (link.pump()) |arrival| {
        try std.testing.expectEqualStrings("response", @tagName(arrival));
        taken += 1;
        if (taken == local_native_link.max_requests) break;
    }
    try std.testing.expectEqual(local_native_link.max_requests, taken);
    _ = try link.send(proto.Now, .now, .{ .core = .cpu0 });
}

test "the session's stop event reaches the window's pump" {
    const gpa = std.testing.allocator;
    var setup = try opened(gpa);
    defer setup.deinit();
    var host = gui_app.wall_clock.Host.init(std.testing.io);
    const clock = host.clock();
    var native = local_native_link.Native.init(std.testing.io, gpa, clock, &setup.context);
    defer native.deinit();
    var link: session_link.Link = undefined;
    link.openNative(&native);

    _ = try link.send(proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .stop });
    _ = try native.serve();
    const ack = link.pump().?;
    try std.testing.expectEqualStrings("response", @tagName(ack));

    _ = try link.send(proto.CoreOnly, .step, .{ .core = .cpu0 });
    var stop_seen = false;
    while (!stop_seen) {
        _ = try native.serve();
        const arrival = link.pump() orelse break;
        if (arrival == .event and arrival.event.topic == @backingInt(proto.Topic.stop)) {
            const stopped = try proto.decode(proto.Stopped, arrival.event.payload);
            try std.testing.expectEqual(proto.Core.cpu0, stopped.core);
            stop_seen = true;
        }
    }
    try std.testing.expect(stop_seen);
}
