//! The off-no-disk acceptance (RA8EMU-1196, slice 16): a served session
//! under `--history off` keeps a RAM-only history, so its recorded run
//! needs no disk at all: the recorder drives the same shapes a disk bind
//! answers, its checkpoint lands in RAM under the name the checkpoint
//! would write, its budget stops with history_full at the share's edge
//! while the storage stays at the committed length, and the batch stays
//! staged for the retry the moment room returns. The history holds no
//! filesystem: the shapes close over allocator-owned bytes only.
const std = @import("std");
const ra8 = @import("ra8");
const ram_mod = ra8.rpc.history_ram;
const recorder_mod = ra8.session.history_recorder;
const record = ra8.session.history_record;
const scheduler = ra8.chip.core.scheduler;

const base: scheduler.Position = .{ .branch = 1, .r = 4, .phase = .cpu0, .o = 0, .gap = .retired };

fn header(seq: u32) record.Header {
    return .{ .position = base, .seq = seq };
}

/// The name the recorder writes a checkpoint under: the hex of the
/// first 128 bits of the bytes' SHA-256, the same digest the disk bind's
/// object space files.
fn checkpointName(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var name: [32]u8 = undefined;
    for (digest[0..16], 0..) |byte, i| {
        _ = std.fmt.bufPrint(name[i * 2 ..][0..2], "{x:0>2}", .{byte}) catch unreachable;
    }
    return name;
}

test "an off history records the run through RAM alone and needs no disk" {
    const gpa = std.testing.allocator;
    const share: u64 = 1 << 20;
    const ram = try ram_mod.RamHistory.open(gpa, share);
    defer ram.deinit();
    var rec = try recorder_mod.Recorder.init(gpa, ram.storage, .{});
    defer rec.deinit();
    rec.objects = ram.object_space;
    rec.disk = ram.budget;
    rec.observe(0);
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "first" });
    try rec.recordBoundary(header(2), .{ .what = .c6_bytes, .body = "second" });
    try rec.checkpoint(header(3), 5, "checkpoint-state");
    try rec.recordBoundary(header(4), .{ .what = .c6_bytes, .body = "third" });
    try rec.commit(1);

    // The whole run lives in this history's own bytes: the committed log
    // and the one checkpoint object, and nothing else in the process
    // wrote anywhere.
    try std.testing.expect(ram.log_bytes.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), ram.objects.items.len);
    try std.testing.expectEqualStrings("checkpoint-state", ram.get(&checkpointName("checkpoint-state")).?);
    // The budget counts exactly what the history holds, read fresh.
    try std.testing.expectEqual(ram.used(), share - (try ram.budget.free(ram.budget.context)));
}

test "an off history stops with history_full at its share and the retry lands when room returns" {
    const gpa = std.testing.allocator;
    const share: u64 = 256;
    const ram = try ram_mod.RamHistory.open(gpa, share);
    defer ram.deinit();
    var rec = try recorder_mod.Recorder.init(gpa, ram.storage, .{});
    defer rec.deinit();
    rec.objects = ram.object_space;
    rec.disk = ram.budget;
    rec.observe(0);

    // A batch the share takes lands.
    try rec.recordBoundary(header(1), .{ .what = .c6_bytes, .body = "fits" });
    try rec.commit(1);
    const held = ram.log_bytes.items.len;
    try std.testing.expect(held > 0);

    // A batch the share cannot take refuses with history_full before
    // any byte moves: the storage stays at the committed length and the
    // batch stays staged for a later retry.
    // A body far larger than the share, built without the repetition
    // operator so the line stays plain.
    var big: [400]u8 = undefined;
    @memset(&big, 'x');
    try rec.recordBoundary(header(2), .{ .what = .c6_bytes, .body = &big });
    try std.testing.expectError(error.HistoryFull, rec.commit(2));
    try std.testing.expectEqual(held, ram.log_bytes.items.len);
    try std.testing.expect(rec.pendingBytes() > 0);

    // The relief frees memory: the share's remainder is read fresh per
    // check, the way a volume's free space is, and the recorder's copy
    // of the budget takes the widened share the same way a volume watch
    // would take a bigger volume, so the same batch lands unchanged.
    ram.share = 1 << 20;
    rec.disk.?.cap = 1 << 20;
    try rec.commit(2);
    try std.testing.expect(ram.log_bytes.items.len > held);
    try std.testing.expectEqual(@as(usize, 0), rec.pendingBytes());
}
