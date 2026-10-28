//! Covers src/session/history/frame_rebuild.zig: a keyframe and a delta
//! rebuild to their exact pixels from payload bytes alone, a delta
//! without its keyframe payload is refused, and a corrupt payload is an
//! error, never wrong pixels.
const std = @import("std");
const ra8 = @import("ra8");
const rebuild = ra8.session.history_frame_rebuild;
const fx = @import("frame_fixture.zig");

const gpa = std.testing.allocator;

test "a keyframe and a delta rebuild bit-exact from their payloads" {
    const key = fx.picture(3, 0);
    const now = fx.picture(3, 140);
    var key_rec = try fx.keyRecord(gpa, fx.at(0, 1), &key);
    defer key_rec.deinit(gpa);
    var delta_rec = try fx.deltaRecord(gpa, fx.at(0, 2), &key, &now);
    defer delta_rec.deinit(gpa);

    var whole = try rebuild.rebuild(gpa, key_rec.header, key_rec.payload, null);
    defer whole.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &key, whole.pixels);
    var changed = try rebuild.rebuild(gpa, delta_rec.header, delta_rec.payload, key_rec.payload);
    defer changed.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &now, changed.pixels);
    try std.testing.expectEqual(@as(u64, 2), changed.position.r);
}

test "a delta needs its keyframe payload" {
    const key = fx.picture(3, 0);
    const now = fx.picture(3, 140);
    var delta_rec = try fx.deltaRecord(gpa, fx.at(0, 2), &key, &now);
    defer delta_rec.deinit(gpa);
    try std.testing.expectError(error.NoKeyframe, rebuild.rebuild(gpa, delta_rec.header, delta_rec.payload, null));
}

test "a truncated payload is an error" {
    const key = fx.picture(3, 0);
    var key_rec = try fx.keyRecord(gpa, fx.at(0, 1), &key);
    defer key_rec.deinit(gpa);
    try std.testing.expectError(error.Truncated, rebuild.rebuild(gpa, key_rec.header, key_rec.payload[0 .. key_rec.payload.len / 2], null));
}
