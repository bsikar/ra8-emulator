const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle owner records roundtrip and reject record injection" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('6');
    const record: history.owner.Record = .{ .host = "fixture-host", .pid = 17, .boot = "boot-1", .started_s = 99 };
    try session.dir.deleteFile(fixture.io, history.layout.files.owner);
    try history.owner.write(fixture.io, session.dir, record);
    try history.owner.write(fixture.io, session.dir, record);
    try std.testing.expectError(error.BadMetadata, history.owner.write(fixture.io, session.dir, .{ .host = "different" }));
    var buffer: [history.owner.max_bytes]u8 = undefined;
    const actual = try history.owner.read(fixture.io, session.dir, &buffer);
    try std.testing.expectEqualStrings(record.host, actual.host);
    try std.testing.expectEqualStrings(record.boot, actual.boot);
    try std.testing.expectEqual(record.pid, actual.pid);
    try std.testing.expectEqual(record.started_s, actual.started_s);
    try std.testing.expectError(error.BadOwner, history.owner.write(fixture.io, session.dir, .{ .host = "x\nhost=attacker" }));
    try std.testing.expectError(error.BadOwner, history.owner.write(fixture.io, session.dir, .{ .host = "" }));
    var native: history.owner.Self = .{};
    try session.dir.deleteFile(fixture.io, history.layout.files.owner);
    try history.owner.write(fixture.io, session.dir, native.record(fixture.io));
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
}

test "host lifecycle malformed truncated and conflicting owner grammar never authorizes ownership" {
    const bad = [_][]const u8{
        "ra8-history-session 1\nhost=local\nhost=other\npid=1\nboot=x\nstarted=1\n",
        "ra8-history-session 1\nhost=local\npid=bad\nboot=x\nstarted=1\n",
        "ra8-history-session 1\nhost=local\npid=1\nboot=x\nstarted=1",
        "ra8-history-session 1\nhost=local\npid=1\nboot=x\n",
        "ra8-history-session 1\nhost=local\npid=1\nboot=x\nstarted=1\nunknown=x\n",
        "ra8-history-session 1\nhost=local\npid=+1\nboot=x\nstarted=1\n",
        "ra8-history-session 1\nhost=local\npid=1_0\nboot=x\nstarted=1\n",
        "ra8-history-session 1\nhost=local\npid=1\nboot=x\nstarted=no\n",
        "ra8-history-session 1\nhost=\npid=1\nboot=x\nstarted=1\n",
    };
    for (bad) |text| try std.testing.expectError(error.Unmarked, history.owner.parse(text));
}
