const std = @import("std");
const h = @import("ra8").host.history;
const f = @import("root_test.zig");

test "host lease provenance rejects a copied claim at another root" {
    var fixture = try f.Fixture.init();
    defer fixture.deinit();
    const id: h.name.Id = @splat('a');
    const held = try h.lock.create(f.io, fixture.cache.dir, &id);
    var leaf: h.name.Buffer = undefined;
    const name = h.name.lease(&leaf, &id);
    const before = (try held.stat(f.io)).inode;
    try h.lease.validate(f.io, fixture.cache.dir, held, &id);
    var bytes: [h.lease.max_bytes]u8 = undefined;
    const count = try held.readPositionalAll(f.io, &bytes, 0);
    held.close(f.io);
    try fixture.kept.dir.writeFile(f.io, .{ .sub_path = name, .data = bytes[0..count] });
    try std.testing.expectError(error.Unmarked, h.lock.take(f.io, fixture.kept.dir, &id));
    try std.testing.expectEqual(before, (try fixture.cache.dir.statFile(f.io, name, .{})).inode);
    const resumed = (try h.lock.take(f.io, fixture.cache.dir, &id)).?;
    try h.lock.retire(f.io, fixture.cache.dir, &id, resumed);
}

test "host lease malformed and linked claims remain protected" {
    var fixture = try f.Fixture.init();
    defer fixture.deinit();
    const id: h.name.Id = @splat('b');
    var leaf: h.name.Buffer = undefined;
    const name = h.name.lease(&leaf, &id);
    try fixture.cache.dir.writeFile(f.io, .{ .sub_path = name, .data = "" });
    try std.testing.expectError(error.Unmarked, h.lock.take(f.io, fixture.cache.dir, &id));
    try fixture.cache.recover();
    try fixture.cache.dir.access(f.io, name, .{});
    try fixture.cache.dir.deleteFile(f.io, name);
    try fixture.tmp.dir.writeFile(f.io, .{ .sub_path = "sentinel", .data = "unchanged" });
    try fixture.hardLink("sentinel", fixture.cache.dir, name);
    try std.testing.expectError(error.Unmarked, h.lock.take(f.io, fixture.cache.dir, &id));
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("unchanged", try fixture.tmp.dir.readFile(f.io, "sentinel", &bytes));
}
