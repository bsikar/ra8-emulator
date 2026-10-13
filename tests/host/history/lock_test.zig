const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle liveness depends on the kernel lock until its handle closes" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('6');
    const id = session.id;
    try std.testing.expectEqual(history.lock.State.held, history.lock.probe(fixture.io, f.cache.dir, &id));
    try std.testing.expect((try history.lock.take(fixture.io, f.cache.dir, &id)) == null);
    fixture.Fixture.abandon(&session);
    try std.testing.expectEqual(history.lock.State.free, history.lock.probe(fixture.io, f.cache.dir, &id));
    const other: history.name.Id = @splat('7');
    try std.testing.expectEqual(history.lock.State.missing, history.lock.probe(fixture.io, f.cache.dir, &other));
    try history.remove.discard(&f.cache, &id, &id);
}
