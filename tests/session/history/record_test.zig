//! Covers src/session/history/record.zig: the frozen kind table, the
//! header every record but the root shares, and the codecs of the
//! records themselves.
const std = @import("std");
const ra8 = @import("ra8");
const record = ra8.session.history_record;
const history_position = ra8.session.history_position;
const scheduler = ra8.chip.core.scheduler;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn baseHeader(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

test "the kind table's numbers and the mandatory bit are frozen" {
    try std.testing.expectEqual(@as(u16, 1), @backingInt(record.Kind.root));
    try std.testing.expectEqual(@as(u16, 2), @backingInt(record.Kind.branch));
    try std.testing.expectEqual(@as(u16, 3), @backingInt(record.Kind.checkpoint));
    try std.testing.expectEqual(@as(u16, 4), @backingInt(record.Kind.intervention));
    try std.testing.expectEqual(@as(u16, 5), @backingInt(record.Kind.boundary));
    try std.testing.expectEqual(@as(u16, 0x8000), record.mandatory_bit);
    try std.testing.expect(record.known(3));
    try std.testing.expect(!record.known(0));
    try std.testing.expectEqual(@as(u16, 6), @backingInt(record.Kind.checkpoint_picture));
    try std.testing.expect(record.known(6));
    try std.testing.expect(!record.known(7));
    try std.testing.expect(record.mandatory(record.mandatory_bit | 99));
    try std.testing.expect(!record.mandatory(99));
    try std.testing.expect(!record.mandatory(@backingInt(record.Kind.root)));
}

test "a branch record round trips through its hand-encoded bytes" {
    const header = baseHeader(7);
    const branch: record.Branch = .{ .id = 2, .parent = 1, .fork_at = base, .reason = .writes };
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try record.encodeBranch(&buf.writer, header, branch);

    // Hand-built: header (position 18 + seq 4), then id, parent, the fork
    // position, the reason.
    var vector: [record.header_len + 4 + 4 + history_position.encoded_len + 1]u8 = undefined;
    std.mem.writeInt(u32, vector[0..4], base.branch, .little);
    std.mem.writeInt(u64, vector[4..12], base.r, .little);
    vector[12] = 0; // phase cpu0
    std.mem.writeInt(u32, vector[13..17], base.o, .little);
    vector[17] = 0; // gap retired
    std.mem.writeInt(u32, vector[18..22], 7, .little); // seq
    std.mem.writeInt(u32, vector[22..26], 2, .little); // id
    std.mem.writeInt(u32, vector[26..30], 1, .little); // parent
    std.mem.writeInt(u32, vector[30..34], base.branch, .little); // fork_at.branch
    std.mem.writeInt(u64, vector[34..42], base.r, .little); // fork_at.r
    vector[42] = 0; // fork_at phase
    std.mem.writeInt(u32, vector[43..47], base.o, .little); // fork_at o
    vector[47] = 0; // fork_at gap
    vector[48] = 1; // reason writes
    try std.testing.expectEqualSlices(u8, &vector, buf.written());
    const decoded = try record.decodeBranch(&vector);
    try std.testing.expectEqual(header, decoded.header);
    try std.testing.expectEqual(@as(u32, 2), decoded.branch.id);
    try std.testing.expectEqual(@as(u32, 1), decoded.branch.parent);
    try std.testing.expectEqual(base, decoded.branch.fork_at);
    try std.testing.expectEqual(record.ForkReason.writes, decoded.branch.reason);
    // A reason byte this table does not know is a hard refusal.
    var bad_reason = vector;
    bad_reason[48] = 9;
    try std.testing.expectError(error.BadValue, record.decodeBranch(&bad_reason));
}

test "events at one position keep the order their sequence numbers say" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try record.encodeIntervention(&buf.writer, baseHeader(7), .{ .what = .tap, .body = "x" });
    try record.encodeIntervention(&buf.writer, baseHeader(8), .{ .what = .button, .body = "yy" });
    const first = try record.decodeIntervention(buf.written()[0..29]);
    const second = try record.decodeIntervention(buf.written()[29..]);
    try std.testing.expectEqual(base, first.header.position);
    try std.testing.expectEqual(@as(u32, 7), first.header.seq);
    try std.testing.expectEqual(@as(u32, 8), second.header.seq);
    try std.testing.expectEqualSlices(u8, "x", first.intervention.body);
    try std.testing.expectEqualSlices(u8, "yy", second.intervention.body);
}

test "a body an older reader does not know is kept, not dropped" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    try record.encodeBoundary(&buf.writer, baseHeader(3), .{ .what = .fault, .body = "why" });
    const decoded = try record.decodeBoundary(buf.written());
    try std.testing.expectEqual(record.Boundary.What.fault, decoded.boundary.what);
    try std.testing.expectEqualSlices(u8, "why", decoded.boundary.body);

    // A what this table does not know decodes to an unnamed value with
    // its body intact; the record stays and a reader that cannot
    // interpret it skips it.
    var unknown = buf.written();
    std.mem.writeInt(u16, unknown[22..24], 0xFFFF, .little);
    const kept = try record.decodeBoundary(unknown);
    try std.testing.expectEqual(@as(u16, 0xFFFF), @backingInt(kept.boundary.what));
    try std.testing.expectEqualSlices(u8, "why", kept.boundary.body);
}

test "a checkpoint record names its object, and a short one is torn" {
    var buf: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer buf.deinit();
    var object: [16]u8 = undefined;
    for (&object, 0..) |*byte, i| byte.* = @intCast(i);
    try record.encodeCheckpoint(&buf.writer, baseHeader(1), .{ .id = 9, .object = object });
    const decoded = try record.decodeCheckpoint(buf.written());
    try std.testing.expectEqual(@as(u32, 9), decoded.checkpoint.id);
    try std.testing.expectEqualSlices(u8, &object, &decoded.checkpoint.object);
    try std.testing.expectError(error.Truncated, record.decodeCheckpoint(buf.written()[0 .. record.header_len + 4]));
}
