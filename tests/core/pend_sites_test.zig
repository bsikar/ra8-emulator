const std = @import("std");
const pend_sites = @import("ra8").core.pend_sites;

test "a fresh table is quiet" {
    var sites = pend_sites.Sites{};
    try std.testing.expect(sites.quiet());
    try std.testing.expectEqual(@as(usize, 0), sites.used);
}

test "stores from one address land in one slot" {
    var sites = pend_sites.Sites{};
    sites.record(0x02002458);
    sites.record(0x02002458);
    sites.record(0x02002458);
    try std.testing.expectEqual(@as(usize, 1), sites.used);
    try std.testing.expectEqual(@as(usize, 3), sites.seen[0].count);
    try std.testing.expectEqual(@as(usize, 0), sites.overflowed);
}

test "two addresses take two slots" {
    var sites = pend_sites.Sites{};
    sites.record(0x02002458);
    sites.record(0x02002CFC);
    sites.record(0x02002458);
    try std.testing.expectEqual(@as(usize, 2), sites.used);
    try std.testing.expect(!sites.quiet());
}

test "the ranking is busiest first" {
    var sites = pend_sites.Sites{};
    sites.record(0x02002CFC);
    sites.record(0x02002458);
    sites.record(0x02002458);
    const ranked = sites.ranked();
    try std.testing.expectEqual(@as(usize, 2), ranked.len);
    try std.testing.expectEqual(@as(u32, 0x02002458), ranked[0].pc);
    try std.testing.expectEqual(@as(usize, 2), ranked[0].count);
    try std.testing.expectEqual(@as(u32, 0x02002CFC), ranked[1].pc);
}

test "a store past the last slot is counted, not dropped" {
    var sites = pend_sites.Sites{};
    var pc: u32 = 0x02000000;
    for (0..pend_sites.limits.sites) |_| {
        sites.record(pc);
        pc += 4;
    }
    try std.testing.expectEqual(@as(usize, pend_sites.limits.sites), sites.used);
    sites.record(0x0200FFFF);
    sites.record(0x0200FFFF);
    try std.testing.expectEqual(@as(usize, 2), sites.overflowed);
    try std.testing.expectEqual(@as(usize, pend_sites.limits.sites), sites.used);
}

test "a known address still counts once the table is full" {
    var sites = pend_sites.Sites{};
    var pc: u32 = 0x02000000;
    for (0..pend_sites.limits.sites) |_| {
        sites.record(pc);
        pc += 4;
    }
    sites.record(0x02000000);
    try std.testing.expectEqual(@as(usize, 0), sites.overflowed);
    const ranked = sites.ranked();
    try std.testing.expectEqual(@as(u32, 0x02000000), ranked[0].pc);
    try std.testing.expectEqual(@as(usize, 2), ranked[0].count);
}
