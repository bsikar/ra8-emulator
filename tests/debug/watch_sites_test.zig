//! Tests for src/debug/watch_sites.zig.
const std = @import("std");
const ra8 = @import("ra8");
const watch_sites = ra8.core.watch_sites;

test "the same site and value fold into one row" {
    var tally = watch_sites.Tally{};
    for (0..452) |_| tally.record(0x0200_22A6, 1);
    try std.testing.expectEqual(@as(usize, 1), tally.used);
    try std.testing.expectEqual(@as(u64, 452), tally.sites[0].writes);
    try std.testing.expectEqual(@as(u64, 0), tally.displaced);
}

test "one site writing two values keeps them apart" {
    var tally = watch_sites.Tally{};
    tally.record(0x0200_2E20, 2);
    tally.record(0x0200_2E20, 2);
    tally.record(0x0200_2E20, 1);
    try std.testing.expectEqual(@as(usize, 2), tally.used);
    var room: [watch_sites.limits.kept]watch_sites.Site = undefined;
    const ranked = tally.ranked(&room);
    try std.testing.expectEqual(@as(u32, 2), ranked[0].value);
    try std.testing.expectEqual(@as(u64, 2), ranked[0].writes);
    try std.testing.expectEqual(@as(u32, 1), ranked[1].value);
}

test "the pairing that located the freeze reads off the tally" {
    var tally = watch_sites.Tally{};
    for (0..452) |_| tally.record(0x0200_22A6, 1);
    for (0..451) |_| tally.record(0x0200_232C, 0);
    var room: [watch_sites.limits.kept]watch_sites.Site = undefined;
    const ranked = tally.ranked(&room);
    try std.testing.expectEqual(@as(u64, 452), ranked[0].writes);
    try std.testing.expectEqual(@as(u64, 451), ranked[1].writes);
    // One increment with no matching decrement, which is the whole finding.
    try std.testing.expectEqual(@as(u64, 1), ranked[0].writes - ranked[1].writes);
}

test "a full table displaces its weakest row and says so" {
    var tally = watch_sites.Tally{};
    for (0..watch_sites.limits.kept) |index| tally.record(@intCast(0x1000 + index * 4), 0);
    for (0..9) |_| tally.record(0x1000, 0);
    tally.record(0xDEAD, 7);
    try std.testing.expectEqual(watch_sites.limits.kept, tally.used);
    try std.testing.expectEqual(@as(u64, 1), tally.displaced);
    // The busy row survived; a one-write row went.
    var room: [watch_sites.limits.kept]watch_sites.Site = undefined;
    try std.testing.expectEqual(@as(u32, 0x1000), tally.ranked(&room)[0].pc);
}

test "a place written once has no tally worth printing" {
    var tally = watch_sites.Tally{};
    try std.testing.expect(tally.quiet());
    tally.record(0x1000, 1);
    try std.testing.expect(tally.quiet());
    tally.record(0x1000, 1);
    try std.testing.expect(!tally.quiet());
}
