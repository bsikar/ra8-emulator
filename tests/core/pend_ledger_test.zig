const std = @import("std");
const ra8 = @import("ra8");
const pend_ledger = ra8.core.pend_ledger;

test "a fresh ledger is quiet and balanced" {
    const books = pend_ledger.Ledger{};
    try std.testing.expect(books.quiet());
    try std.testing.expect(books.balanced());
    try std.testing.expectEqual(@as(?f64, null), books.asksPerRise(0));
}

test "the wdt_supervisor_demo reading closes" {
    const books = pend_ledger.Ledger{ .raised = 11, .entered = 8, .unpended = 3 };
    try std.testing.expect(!books.quiet());
    try std.testing.expect(books.balanced());
    try std.testing.expectEqual(@as(u64, 0), books.outstanding());
    try std.testing.expectEqual(@as(u64, 0), books.phantom());
}

test "one bit still up at the end is allowed" {
    const books = pend_ledger.Ledger{ .raised = 4, .entered = 3, .unpended = 0 };
    try std.testing.expectEqual(@as(u64, 1), books.outstanding());
    try std.testing.expect(books.balanced());
}

test "two rises nobody disposed of is a leak" {
    const books = pend_ledger.Ledger{ .raised = 5, .entered = 3, .unpended = 0 };
    try std.testing.expectEqual(@as(u64, 2), books.outstanding());
    try std.testing.expect(!books.balanced());
}

test "a disposal with no rise behind it is never balanced" {
    const books = pend_ledger.Ledger{ .raised = 3, .entered = 3, .unpended = 1 };
    try std.testing.expectEqual(@as(u64, 1), books.phantom());
    try std.testing.expectEqual(@as(u64, 0), books.outstanding());
    try std.testing.expect(!books.balanced());
}

test "asks per rise is the stores over the rises" {
    const books = pend_ledger.Ledger{ .raised = 11, .entered = 8, .unpended = 3 };
    const ratio = books.asksPerRise(387) orelse return error.TestExpectedRatio;
    try std.testing.expect(ratio > 35.1 and ratio < 35.2);
}

test "one store per rise is the shape a chip would show" {
    const books = pend_ledger.Ledger{ .raised = 3, .entered = 3, .unpended = 0 };
    const ratio = books.asksPerRise(3) orelse return error.TestExpectedRatio;
    try std.testing.expectEqual(@as(f64, 1.0), ratio);
}
