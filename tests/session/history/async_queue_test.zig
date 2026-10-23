//! Tests for src/session/history/async_queue.zig.
//!
//! Covers:
//! - exact capacity boundary
//! - per-item overhead accounting
//! - ordering across sources
//! - overflow latch and counters
//! - oversize item
//! - drain then refill
//! - clear report
//! - 16 MiB default test that does not take long
//! - tail-drop preservation of queued prefix
const std = @import("std");
const ra8 = @import("ra8");
const async_queue = ra8.session.history_async_queue;

const AsyncQueue = async_queue.AsyncQueue;
const Source = async_queue.Source;
const Item = async_queue.Item;

test "exact capacity boundary" {
    const gpa = std.testing.allocator;
    // item_overhead = 32. With payload 18, each item costs 50 bytes.
    // Capacity of 100 fits exactly two 50-byte items.
    var q = AsyncQueue.init(gpa, 100);
    defer q.deinit();

    const p1 = "0123456789abcdefgh";
    try std.testing.expectEqual(@as(usize, 18), p1.len);

    try std.testing.expect(try q.push(.c6_bytes, 1000, p1));
    try std.testing.expectEqual(@as(usize, 50), q.usedBytes());
    try std.testing.expectEqual(@as(usize, 1), q.count());
    try std.testing.expectEqual(@as(usize, 50), q.availableBytes());

    try std.testing.expect(try q.push(.usbip, 2000, p1));
    try std.testing.expectEqual(@as(usize, 100), q.usedBytes());
    try std.testing.expectEqual(@as(usize, 2), q.count());
    try std.testing.expectEqual(@as(usize, 0), q.availableBytes());

    // Boundary check: an additional 0-byte item costs 32, which exceeds 100.
    try std.testing.expect(!try q.push(.camera, 3000, ""));
    try std.testing.expectEqual(@as(usize, 100), q.usedBytes());
    try std.testing.expectEqual(@as(usize, 2), q.count());
    try std.testing.expect(q.hasOverflow());
}

test "per-item overhead accounting" {
    const gpa = std.testing.allocator;
    // Exactly space for 3 zero-byte items: 3 * 32 = 96 bytes.
    var q = AsyncQueue.init(gpa, async_queue.item_overhead * 3);
    defer q.deinit();

    try std.testing.expect(try q.push(.c6_bytes, 10, ""));
    try std.testing.expectEqual(async_queue.item_overhead, q.usedBytes());

    try std.testing.expect(try q.push(.c6_answer, 20, ""));
    try std.testing.expectEqual(async_queue.item_overhead * 2, q.usedBytes());

    try std.testing.expect(try q.push(.usbip, 30, ""));
    try std.testing.expectEqual(async_queue.item_overhead * 3, q.usedBytes());
    try std.testing.expectEqual(@as(usize, 3), q.count());

    // 4th zero-byte item is refused because overhead is accounted for.
    try std.testing.expect(!try q.push(.camera, 40, ""));
    try std.testing.expectEqual(async_queue.item_overhead * 3, q.usedBytes());
    try std.testing.expectEqual(@as(usize, 3), q.count());
    try std.testing.expectEqual(@as(u64, 1), q.overflowState().droppedItemsFor(.camera));
}

test "ordering across sources" {
    const gpa = std.testing.allocator;
    var q = AsyncQueue.init(gpa, 1024);
    defer q.deinit();

    try std.testing.expect(try q.push(.c6_bytes, 100, "net-pkt-1"));
    try std.testing.expect(try q.push(.usbip, 150, "urb-submit"));
    try std.testing.expect(try q.push(.camera, 200, "frame-0"));
    try std.testing.expect(try q.push(.c6_answer, 250, "rpc-ack"));

    const Collector = struct {
        sources: [4]Source = undefined,
        times: [4]u64 = undefined,
        idx: usize = 0,

        pub fn visit(self: *@This(), item: Item) void {
            self.sources[self.idx] = item.source;
            self.times[self.idx] = item.arrival_ns;
            self.idx += 1;
        }
    };

    var collector = Collector{};
    const drained = try q.drain(&collector);
    try std.testing.expectEqual(@as(usize, 4), drained);
    try std.testing.expectEqual(@as(usize, 4), collector.idx);

    try std.testing.expectEqual(Source.c6_bytes, collector.sources[0]);
    try std.testing.expectEqual(@as(u64, 100), collector.times[0]);

    try std.testing.expectEqual(Source.usbip, collector.sources[1]);
    try std.testing.expectEqual(@as(u64, 150), collector.times[1]);

    try std.testing.expectEqual(Source.camera, collector.sources[2]);
    try std.testing.expectEqual(@as(u64, 200), collector.times[2]);

    try std.testing.expectEqual(Source.c6_answer, collector.sources[3]);
    try std.testing.expectEqual(@as(u64, 250), collector.times[3]);

    try std.testing.expect(q.isEmpty());
}

test "overflow latch and counters" {
    const gpa = std.testing.allocator;
    // Capacity 80. Item overhead 32. Item with len 8 costs 40. Fits 2 items.
    var q = AsyncQueue.init(gpa, 80);
    defer q.deinit();

    try std.testing.expect(try q.push(.c6_bytes, 100, "12345678"));
    try std.testing.expect(try q.push(.usbip, 200, "abcdefgh"));
    try std.testing.expect(!q.hasOverflow());

    // First refused item at t=300: c6_bytes payload 10
    try std.testing.expect(!try q.push(.c6_bytes, 300, "0123456789"));
    // Second refused item at t=400: camera payload 20
    try std.testing.expect(!try q.push(.camera, 400, "12345678901234567890"));
    // Third refused item at t=500: c6_bytes payload 5
    try std.testing.expect(!try q.push(.c6_bytes, 500, "hello"));

    const state = q.overflowState();
    try std.testing.expect(state.hasDropped());
    try std.testing.expectEqual(@as(?u64, 300), state.first_drop_ns);

    try std.testing.expectEqual(@as(u64, 2), state.droppedItemsFor(.c6_bytes));
    try std.testing.expectEqual(@as(u64, 15), state.droppedBytesFor(.c6_bytes));

    try std.testing.expectEqual(@as(u64, 1), state.droppedItemsFor(.camera));
    try std.testing.expectEqual(@as(u64, 20), state.droppedBytesFor(.camera));

    try std.testing.expectEqual(@as(u64, 0), state.droppedItemsFor(.c6_answer));
    try std.testing.expectEqual(@as(u64, 0), state.droppedBytesFor(.c6_answer));
    try std.testing.expectEqual(@as(u64, 0), state.droppedItemsFor(.usbip));
    try std.testing.expectEqual(@as(u64, 0), state.droppedBytesFor(.usbip));

    try std.testing.expectEqual(@as(u64, 3), state.totalDroppedItems());
    try std.testing.expectEqual(@as(u64, 35), state.totalDroppedBytes());

    // Tail-drop keeps older queued prefix untouched.
    const PrefixChecker = struct {
        seen: usize = 0,
        pub fn visit(self: *@This(), item: Item) void {
            if (self.seen == 0) {
                std.testing.expectEqual(Source.c6_bytes, item.source) catch {};
                std.testing.expectEqualStrings("12345678", item.data) catch {};
            } else if (self.seen == 1) {
                std.testing.expectEqual(Source.usbip, item.source) catch {};
                std.testing.expectEqualStrings("abcdefgh", item.data) catch {};
            }
            self.seen += 1;
        }
    };
    var checker = PrefixChecker{};
    const drained = try q.drain(&checker);
    try std.testing.expectEqual(@as(usize, 2), drained);
    try std.testing.expectEqual(@as(usize, 2), checker.seen);
}

test "oversize item" {
    const gpa = std.testing.allocator;
    var q = AsyncQueue.init(gpa, 50);
    defer q.deinit();

    // Payload len 50 alone equals capacity, with overhead 50 + 32 = 82 > 50.
    var big: [50]u8 = @splat(0xAA);
    try std.testing.expect(!try q.push(.camera, 12345, &big));

    try std.testing.expect(q.hasOverflow());
    try std.testing.expectEqual(@as(?u64, 12345), q.overflowState().first_drop_ns);
    try std.testing.expectEqual(@as(u64, 1), q.overflowState().droppedItemsFor(.camera));
    try std.testing.expectEqual(@as(u64, 50), q.overflowState().droppedBytesFor(.camera));
    try std.testing.expectEqual(@as(usize, 0), q.usedBytes());
    try std.testing.expectEqual(@as(usize, 0), q.count());
}

test "drain then refill" {
    const gpa = std.testing.allocator;
    var q = AsyncQueue.init(gpa, 200);
    defer q.deinit();

    try std.testing.expect(try q.push(.c6_bytes, 1, "packet-1"));
    try std.testing.expect(try q.push(.usbip, 2, "packet-2"));
    try std.testing.expectEqual(@as(usize, 2), q.count());

    var sum_lens: usize = 0;
    const Drainer = struct {
        sum: *usize,
        pub fn visit(self: @This(), item: Item) void {
            self.sum.* += item.data.len;
        }
    };
    _ = try q.drain(Drainer{ .sum = &sum_lens });
    try std.testing.expectEqual(@as(usize, 16), sum_lens);
    try std.testing.expectEqual(@as(usize, 0), q.usedBytes());
    try std.testing.expect(q.isEmpty());

    // Refill
    try std.testing.expect(try q.push(.camera, 3, "new-packet-3"));
    try std.testing.expect(try q.push(.c6_answer, 4, "new-packet-4"));
    try std.testing.expectEqual(@as(usize, 2), q.count());

    _ = try q.drain(Drainer{ .sum = &sum_lens });
    try std.testing.expectEqual(@as(usize, 40), sum_lens);
    try std.testing.expectEqual(@as(usize, 0), q.usedBytes());
    try std.testing.expect(q.isEmpty());
}

test "clear report" {
    const gpa = std.testing.allocator;
    var q = AsyncQueue.init(gpa, 500);
    defer q.deinit();

    try std.testing.expect(try q.push(.c6_bytes, 10, "1234567890"));
    try std.testing.expect(try q.push(.c6_bytes, 11, "abcde"));
    try std.testing.expect(try q.push(.usbip, 20, "payload-usb"));
    try std.testing.expect(try q.push(.camera, 30, "frame"));

    const report = q.clear();

    try std.testing.expectEqual(@as(usize, 4), report.items);
    try std.testing.expectEqual(@as(usize, 31), report.bytes);

    try std.testing.expectEqual(@as(usize, 2), report.itemsFor(.c6_bytes));
    try std.testing.expectEqual(@as(usize, 15), report.bytesFor(.c6_bytes));

    try std.testing.expectEqual(@as(usize, 1), report.itemsFor(.usbip));
    try std.testing.expectEqual(@as(usize, 11), report.bytesFor(.usbip));

    try std.testing.expectEqual(@as(usize, 1), report.itemsFor(.camera));
    try std.testing.expectEqual(@as(usize, 5), report.bytesFor(.camera));

    try std.testing.expectEqual(@as(usize, 0), report.itemsFor(.c6_answer));
    try std.testing.expectEqual(@as(usize, 0), report.bytesFor(.c6_answer));

    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), q.usedBytes());
}

test "16 MiB default test that does not take long" {
    const gpa = std.testing.allocator;
    var q = AsyncQueue.init(gpa, async_queue.default_capacity);
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 16 * 1024 * 1024), q.capacity());
    try std.testing.expectEqual(@as(usize, 0), q.usedBytes());
    try std.testing.expect(q.isEmpty());

    // Push 64 KiB buffer
    var buf64: [64 * 1024]u8 = undefined;
    @memset(&buf64, 0x42);
    try std.testing.expect(try q.push(.c6_bytes, 1000, &buf64));

    // Push 1 MiB buffer
    const buf1m = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(buf1m);
    @memset(buf1m, 0x55);
    try std.testing.expect(try q.push(.camera, 2000, buf1m));

    try std.testing.expectEqual(@as(usize, 2), q.count());
    const expected_used = (async_queue.item_overhead + buf64.len) + (async_queue.item_overhead + buf1m.len);
    try std.testing.expectEqual(expected_used, q.usedBytes());

    var total_drained_bytes: usize = 0;
    const Counter = struct {
        total: *usize,
        pub fn visit(self: @This(), item: Item) void {
            self.total.* += item.data.len;
        }
    };
    const drained = try q.drain(Counter{ .total = &total_drained_bytes });
    try std.testing.expectEqual(@as(usize, 2), drained);
    try std.testing.expectEqual(buf64.len + buf1m.len, total_drained_bytes);
    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), q.usedBytes());
}
