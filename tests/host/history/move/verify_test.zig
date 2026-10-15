const std = @import("std");
const move = @import("ra8").host.history.move;
const wire = move.wire;
const verify = move.verify;
const Id = @import("ra8").host.history.name.Id;

const nonce: Id = @splat('a');
const operation: Id = @splat('b');
const earlier: Id = @splat('c');
const proof: wire.Proof = .{ .anchor = @splat('1'), .note = @splat('2') };
/// The same note under an anchor that has since gained its COMMIT flag.
const stale: wire.Proof = .{ .anchor = @splat('3'), .note = @splat('2') };

fn request() wire.Request {
    return .{ .version = wire.version, .nonce = nonce, .operation = operation, .proof = proof, .source = .{ .path = "C:\\cache", .marker = "m" }, .target = .{ .path = "D:\\kept", .marker = "m" }, .from = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .to = "trash-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .ready_ms = 10_000, .commit_ms = 5_000, .drain_ms = 5_000 };
}

fn proved() verify.Proved {
    const value = request();
    return .{ .nonce = nonce, .from = value.from, .to = value.to, .source = value.source.path, .target = value.target.path, .proof = proof };
}

fn reply(phase: wire.Phase) wire.Reply {
    return .{ .version = wire.version, .nonce = nonce, .operation = operation, .proof = proof, .phase = phase, .pid = 4321, .birth = 133_000_000_000_000_000, .source_inode = 7, .source_root = 8, .target_root = 9 };
}

fn commit() wire.Commit {
    return .{ .version = wire.version, .nonce = nonce, .operation = operation, .proof = proof, .commit = true };
}

const sent: verify.Sent = .{ .nonce = nonce, .operation = operation, .proof = proof };

test "a peer refuses a request frame of another version, a bad id, unbounded phases or a path" {
    try verify.frame(request());
    var bad = request();
    bad.version = 2;
    try std.testing.expectError(error.BadFrame, verify.frame(bad));
    bad = request();
    bad.nonce = @splat('Z');
    try std.testing.expectError(error.BadFrame, verify.frame(bad));
    bad = request();
    bad.operation = @splat('Z');
    try std.testing.expectError(error.BadFrame, verify.frame(bad));
    for ([_][3]u32{ .{ 0, 5_000, 5_000 }, .{ 10_000, 0, 5_000 }, .{ 10_000, 5_000, 0 }, .{ 30_000, 20_000, 20_000 } }) |ms| {
        bad = request();
        bad.ready_ms, bad.commit_ms, bad.drain_ms = ms;
        try std.testing.expectError(error.BadBounds, verify.frame(bad));
    }
    for ([_][]const u8{ "..", "a/b", "C:\\x", "" }) |path| {
        bad = request();
        bad.to = path;
        try std.testing.expectError(error.BadName, verify.frame(bad));
    }
}

test "a peer refuses a request that names anything but the intent it proved" {
    try verify.bound(request(), proved());
    var bad = request();
    bad.nonce = earlier;
    try std.testing.expectError(error.IdentityConflict, verify.bound(bad, proved()));
    bad = request();
    bad.from = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    try std.testing.expectError(error.IdentityConflict, verify.bound(bad, proved()));
    bad = request();
    bad.to = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try std.testing.expectError(error.IdentityConflict, verify.bound(bad, proved()));
    bad = request();
    bad.source.path = "C:\\other";
    try std.testing.expectError(error.IdentityConflict, verify.bound(bad, proved()));
    bad = request();
    bad.target.path = "C:\\cache";
    try std.testing.expectError(error.IdentityConflict, verify.bound(bad, proved()));
    bad = request();
    bad.proof = stale;
    try std.testing.expectError(error.IdentityConflict, verify.bound(bad, proved()));
    bad = request();
    bad.proof.note = @splat('f');
    try std.testing.expectError(error.IdentityConflict, verify.bound(bad, proved()));
}

test "a peer honors only its own exchange's COMMIT" {
    try verify.commit(request(), commit());
    var bad = commit();
    bad.operation = earlier;
    try std.testing.expectError(error.BadFrame, verify.commit(request(), bad));
    bad = commit();
    bad.nonce = earlier;
    try std.testing.expectError(error.BadFrame, verify.commit(request(), bad));
    bad = commit();
    bad.proof = stale;
    try std.testing.expectError(error.BadFrame, verify.commit(request(), bad));
    bad = commit();
    bad.version = 2;
    try std.testing.expectError(error.BadFrame, verify.commit(request(), bad));
    bad = commit();
    bad.commit = false;
    try std.testing.expectError(error.Aborted, verify.commit(request(), bad));
}

test "a caller refuses a reply from another exchange, phase or unnamed peer" {
    try verify.reply(sent, reply(.bound), .bound);
    try verify.reply(sent, reply(.done), .done);
    try std.testing.expectError(error.BadFrame, verify.reply(sent, reply(.done), .bound));
    try std.testing.expectError(error.BadFrame, verify.reply(sent, reply(.starting), .bound));
    var bad = reply(.bound);
    bad.operation = earlier;
    try std.testing.expectError(error.BadFrame, verify.reply(sent, bad, .bound));
    bad = reply(.bound);
    bad.nonce = earlier;
    try std.testing.expectError(error.BadFrame, verify.reply(sent, bad, .bound));
    bad = reply(.bound);
    bad.proof = stale;
    try std.testing.expectError(error.BadFrame, verify.reply(sent, bad, .bound));
    bad = reply(.bound);
    bad.pid = 0;
    try std.testing.expectError(error.BadFrame, verify.reply(sent, bad, .bound));
    bad = reply(.bound);
    bad.birth = 0;
    try std.testing.expectError(error.BadFrame, verify.reply(sent, bad, .bound));
    bad = reply(.bound);
    bad.version = 2;
    try std.testing.expectError(error.BadFrame, verify.reply(sent, bad, .bound));
    bad = reply(.bound);
    bad.status = .refused;
    try std.testing.expectError(error.BadFrame, verify.reply(sent, bad, .bound));
}

test "a done reply from another peer or over other pins is refused" {
    try verify.pair(reply(.bound), reply(.done));
    var bad = reply(.done);
    bad.pid += 1;
    try std.testing.expectError(error.BadFrame, verify.pair(reply(.bound), bad));
    bad = reply(.done);
    bad.birth += 1;
    try std.testing.expectError(error.BadFrame, verify.pair(reply(.bound), bad));
    bad = reply(.done);
    bad.source_inode += 1;
    try std.testing.expectError(error.BadFrame, verify.pair(reply(.bound), bad));
    bad = reply(.done);
    bad.source_root += 1;
    try std.testing.expectError(error.BadFrame, verify.pair(reply(.bound), bad));
    bad = reply(.done);
    bad.target_root += 1;
    try std.testing.expectError(error.BadFrame, verify.pair(reply(.bound), bad));
}
