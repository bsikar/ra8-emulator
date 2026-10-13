const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle actual physical RAM supplies the bounded default" {
    const physical = try history.resources.physicalRam();
    try std.testing.expect(physical > 0);
    const cap = try history.resources.ramBudget(null);
    try std.testing.expectEqual(history.budget.defaultRam(physical), cap);
    try std.testing.expect(cap >= 256 * history.budget.bytes.mib);
    try std.testing.expect(cap <= history.budget.bytes.gib);
}

test "host lifecycle actual owned volume provides free-floor inputs" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    const volume = try history.resources.volume(fixture.allocator, fixture.io, f.cache.dir);
    try std.testing.expect(volume.total > 0);
    try std.testing.expect(volume.available <= volume.total);
}
