//! Covers src/session/history/seek_target.zig: every target form parses to
//! the typed value it names, and text the grammar cannot name exactly is
//! refused rather than guessed.
const std = @import("std");
const ra8 = @import("ra8");
const seek = ra8.session.history_seek_target;

test "absolute and relative virtual times parse to nanoseconds" {
    try std.testing.expectEqual(@as(i64, 12_402_000_000), (try seek.parse("12.402s")).time.ns);
    try std.testing.expectEqual(@as(i64, 500_000_000), (try seek.parse("0.5s")).time.ns);
    try std.testing.expectEqual(@as(i64, 1500), (try seek.parse("1.5us")).time.ns);
    try std.testing.expectEqual(@as(i64, 500), (try seek.parse("500ns")).time.ns);
    try std.testing.expectEqual(@as(i64, 1), (try seek.parse("1.0ns")).time.ns);
    try std.testing.expect(!(try seek.parse("12.402s")).time.relative);
    try std.testing.expectEqual(@as(i64, 500_000_000), (try seek.parse("+500ms")).time.ns);
    try std.testing.expect((try seek.parse("+500ms")).time.relative);
    try std.testing.expectEqual(@as(i64, -2_000_000_000), (try seek.parse("-2s")).time.ns);
    try std.testing.expect((try seek.parse("-2s")).time.relative);
}

test "times the units cannot represent exactly are refused" {
    try std.testing.expectError(error.BadValue, seek.parse("1.5ns"));
    try std.testing.expectError(error.BadValue, seek.parse("12"));
    try std.testing.expectError(error.BadValue, seek.parse("12x"));
    try std.testing.expectError(error.BadValue, seek.parse("12."));
    try std.testing.expectError(error.BadValue, seek.parse(""));
    try std.testing.expectError(error.BadValue, seek.parse("18446744073709551616s"));
}

test "percents parse to basis points and stay inside the span" {
    try std.testing.expectEqual(@as(i64, 2500), (try seek.parse("25%")).percent.basis_points);
    try std.testing.expectEqual(@as(i64, 1250), (try seek.parse("12.5%")).percent.basis_points);
    try std.testing.expect(!(try seek.parse("25%")).percent.relative);
    try std.testing.expectEqual(@as(i64, 1000), (try seek.parse("+10%")).percent.basis_points);
    try std.testing.expectEqual(@as(i64, -500), (try seek.parse("-5%")).percent.basis_points);
    try std.testing.expect((try seek.parse("+10%")).percent.relative);
    try std.testing.expectEqual(@as(i64, 0), (try seek.parse("0%")).percent.basis_points);
}

test "percents beyond two fraction digits or the span are refused" {
    try std.testing.expectError(error.BadValue, seek.parse("12.501%"));
    try std.testing.expectError(error.BadValue, seek.parse("101%"));
    try std.testing.expectError(error.BadValue, seek.parse("100.0001%"));
    try std.testing.expect((try seek.parse("100.0000%")).percent.basis_points == 10_000);
}

test "positions parse their four fields and an optional branch" {
    const bare = try seek.parse("3:cpu1:4:polled");
    try std.testing.expectEqual(@as(u64, 3), bare.position.position.r);
    try std.testing.expectEqual(.cpu1, bare.position.position.phase);
    try std.testing.expectEqual(@as(u32, 4), bare.position.position.o);
    try std.testing.expectEqual(.polled, bare.position.position.gap);
    try std.testing.expect(!bare.position.branch_named);

    const named = try seek.parse("2:3:cpu0:1:retired");
    try std.testing.expectEqual(@as(u32, 2), named.position.position.branch);
    try std.testing.expectEqual(@as(u64, 3), named.position.position.r);
    try std.testing.expectEqual(.cpu0, named.position.position.phase);
    try std.testing.expectEqual(@as(u32, 1), named.position.position.o);
    try std.testing.expectEqual(.retired, named.position.position.gap);
    try std.testing.expect(named.position.branch_named);
}

test "positions with a wrong phase, gap or field count are refused" {
    try std.testing.expectError(error.BadValue, seek.parse("3:cpu2:4:polled"));
    try std.testing.expectError(error.BadValue, seek.parse("3:cpu1:4:later"));
    try std.testing.expectError(error.BadValue, seek.parse("3:cpu1:4"));
    try std.testing.expectError(error.BadValue, seek.parse("1:2:3:cpu1:4:polled"));
    try std.testing.expectError(error.BadValue, seek.parse("a:cpu1:4:polled"));
}

test "frames parse an index and the two steps" {
    try std.testing.expectEqual(@as(u64, 12), (try seek.parse("frame 12")).frame.index);
    try std.testing.expect((try seek.parse("prev")).frame == .prev);
    try std.testing.expect((try seek.parse("next")).frame == .next);
    try std.testing.expectError(error.BadValue, seek.parse("frame"));
    try std.testing.expectError(error.BadValue, seek.parse("frame x"));
    try std.testing.expectError(error.BadValue, seek.parse("prev x"));
    try std.testing.expectError(error.BadValue, seek.parse("next 1"));
}

test "iterations count from one and bookmarks take the rest of the line" {
    try std.testing.expectEqual(@as(u64, 7), (try seek.parse("iter 7")).iteration.n);
    try std.testing.expectError(error.BadValue, seek.parse("iter 0"));
    const name = try seek.parse("bm main_loop");
    try std.testing.expectEqualStrings("main_loop", name.bookmark.name);
    try std.testing.expectEqualStrings("run:1", (try seek.parse("bm run:1")).bookmark.name);
    try std.testing.expectError(error.BadValue, seek.parse("bm"));
}

test "arrivals parse an address and a count from one" {
    const hex = try seek.parse("arrival 2 0x08001abc");
    try std.testing.expectEqual(@as(u32, 0x08001abc), hex.point.address);
    try std.testing.expectEqual(@as(u64, 2), hex.point.nth);
    const dec = try seek.parse("arrival 1 4096");
    try std.testing.expectEqual(@as(u32, 4096), dec.point.address);
    try std.testing.expectError(error.BadValue, seek.parse("arrival 0 0x10"));
    try std.testing.expectError(error.BadValue, seek.parse("arrival 2"));
    try std.testing.expectError(error.BadValue, seek.parse("arrival 2 0x"));
    try std.testing.expectError(error.BadValue, seek.parse("arrival 2 0x10 0x20"));
}

test "keyword forms are recognized before the bare forms" {
    // A bookmark may carry colons and percent signs of its own.
    try std.testing.expectEqualStrings("25%", (try seek.parse("bm 25%")).bookmark.name);
    // Two colon fields is a malformed position, not a time.
    try std.testing.expectError(error.BadValue, seek.parse("12:30"));
    try std.testing.expectError(error.BadValue, seek.parse("unknown 5"));
}

test "a marker target names an armed marker and optionally its Nth arrival" {
    const first = try seek.parse("marker loop");
    try std.testing.expectEqualStrings("loop", first.marker.name);
    try std.testing.expectEqual(@as(u64, 1), first.marker.nth);
    const third = try seek.parse("marker loop 3");
    try std.testing.expectEqual(@as(u64, 3), third.marker.nth);
    try std.testing.expectError(error.BadValue, seek.parse("marker loop 0"));
    try std.testing.expectError(error.BadValue, seek.parse("marker a b"));
}
