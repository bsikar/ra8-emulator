//! Covers src/gui/triple_buffer.zig: a reader sees nothing until a
//! publish, then only the newest one once; the three slots stay distinct;
//! and a reader thread racing a writer thread never sees a torn snapshot
//! or time running backwards.
const std = @import("std");
const ra8 = @import("ra8");
const TripleBuffer = ra8.gui.triple_buffer.TripleBuffer;

test "nothing until a publish, then the newest publish once" {
    var buffer = TripleBuffer(u32).init(0);
    try std.testing.expect(buffer.latest() == null);
    buffer.writeSlot().* = 1;
    buffer.publish();
    buffer.writeSlot().* = 2;
    buffer.publish();
    try std.testing.expectEqual(@as(u32, 2), buffer.latest().?.*);
    try std.testing.expect(buffer.latest() == null);
    try std.testing.expectEqual(@as(u32, 2), buffer.current().*);
    try std.testing.expectEqual(@as(u64, 2), buffer.published);
}

test "writer, middle and reader always hold three different slots" {
    var buffer = TripleBuffer(u8).init(0);
    for (0..20) |i| {
        if (i % 3 == 0) buffer.publish() else _ = buffer.latest();
        const middle = buffer.shared.load(.monotonic) & 0b11;
        try std.testing.expect(buffer.back != buffer.front);
        try std.testing.expect(buffer.back != middle and buffer.front != middle);
    }
}

const Snapshot = struct { words: [64]u64 };
const rounds = 50_000;

fn write(buffer: *TripleBuffer(Snapshot)) void {
    for (1..rounds + 1) |n| {
        @memset(&buffer.writeSlot().words, n);
        buffer.publish();
    }
}

test "a racing reader never sees a torn snapshot or time going back" {
    var buffer = TripleBuffer(Snapshot).init(.{ .words = @splat(0) });
    const writer = try std.Thread.spawn(.{}, write, .{&buffer});
    var last: u64 = 0;
    var seen: usize = 0;
    while (last < rounds) {
        const snap = buffer.latest() orelse continue;
        const first = snap.words[0];
        for (snap.words) |w| try std.testing.expectEqual(first, w);
        try std.testing.expect(first > last);
        last = first;
        seen += 1;
    }
    writer.join();
    try std.testing.expect(seen > 0);
}
