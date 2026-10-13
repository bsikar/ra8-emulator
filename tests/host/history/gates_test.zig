const std = @import("std");
const h = @import("ra8").host.history;
const f = @import("root_test.zig");
test "host gates serialize both roots and deduplicate identical resolved handles" {
    var fixture = try f.Fixture.init();
    defer fixture.deinit();
    var duplicate = try h.base.Base.existing(f.allocator, f.io, fixture.cache.path, .cache);
    defer duplicate.close();
    var shared = try h.gates.Pair.acquire(&fixture.cache, &duplicate);
    try std.testing.expect(shared.second == null);
    shared.release();
    var both = try h.gates.Pair.acquire(&fixture.kept, &fixture.cache);
    defer both.release();
    try std.testing.expect(both.second != null);
    for ([_]*const h.base.Base{ &fixture.cache, &fixture.kept }) |root| {
        const file = try h.metadata.open(f.io, root.dir, h.layout.root.gate, .read_write);
        defer file.close(f.io);
        try std.testing.expect(!try file.tryLock(f.io, .exclusive));
    }
}
