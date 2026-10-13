const std = @import("std");
const builtin = @import("builtin");
const host = @import("ra8").host;
const stops = host.stops;
const fixture = @import("history/root_test.zig");

test "host lifecycle stop requests retain the first reason and reset for reuse" {
    stops.reset();
    defer stops.reset();
    try std.testing.expect(!stops.requested());
    stops.request(.interrupt);
    stops.request(.terminate);
    try std.testing.expectEqual(stops.Reason.interrupt, stops.why());
    stops.reset();
    try std.testing.expectEqual(stops.Reason.none, stops.why());
    try std.testing.expectEqual(stops.Reason.console_close, stops.consoleReason(stops.console.close).?);
    try std.testing.expect(stops.consoleReason(999) == null);
    try std.testing.expect(stops.held(.console_close));
    try std.testing.expect(!stops.held(.interrupt));
}

test "host lifecycle held cleanup wait honors completion and timeout" {
    stops.reset();
    defer stops.reset();
    const callbacks = struct {
        var elapsed: u32 = 0;
        fn pause(ms: u32) void {
            elapsed += ms;
        }
        fn finish(ms: u32) void {
            elapsed += ms;
            stops.finished();
        }
    };
    callbacks.elapsed = 0;
    try std.testing.expect(!stops.awaitFinished(40, callbacks.pause));
    try std.testing.expectEqual(@as(u32, 40), callbacks.elapsed);
    callbacks.elapsed = 0;
    try std.testing.expect(stops.awaitFinished(40, callbacks.finish));
    try std.testing.expectEqual(@as(u32, 10), callbacks.elapsed);
}

test "host lifecycle Windows held handler completes actual owned filesystem cleanup within 4s" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    stops.reset();
    defer stops.reset();
    try stops.install();
    defer stops.uninstall();
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('8');
    const id = session.id;
    const file = try host.history.scratch.open(&session, .frames, "frame-0");
    try file.writePositionalAll(fixture.io, "a real temporary frame", 0);
    const Handler = struct {
        fn dispatch() void {
            _ = stops.consoleEvent(stops.console.close);
        }
    };
    const start = std.Io.Timestamp.now(fixture.io, .awake).toMilliseconds();
    const thread = try std.Thread.spawn(.{}, Handler.dispatch, .{});
    const deadline = start + 1000;
    while (!stops.requested() and std.Io.Timestamp.now(fixture.io, .awake).toMilliseconds() < deadline) {
        try std.Io.sleep(fixture.io, .fromMilliseconds(1), .awake);
    }
    const requested = stops.requested();
    file.close(fixture.io);
    const outcome = session.close(null, .stay);
    stops.finished();
    thread.join();
    const elapsed = std.Io.Timestamp.now(fixture.io, .awake).toMilliseconds() - start;
    std.debug.print("CHECK Windows held handler filesystem cleanup elapsed_ms={d} bound_ms=4000\n", .{elapsed});
    try std.testing.expect(requested);
    try std.testing.expectEqual(host.history.session.Outcome.deleted, try outcome);
    try std.testing.expectError(error.NotFound, f.cache.owns(&id));
    try std.testing.expect(elapsed <= 4000);
    // This exercises the installed handler's shared dispatch. Native OS
    // delivery and kill/restart require a separate isolated child probe.
}
