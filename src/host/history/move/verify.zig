//! Each side checks every frame of one native move against what it already
//! holds itself. A frame that is forged, stale, replayed from another
//! exchange, missing a field or naming another root is refused, and a peer
//! refusing a frame renames nothing.
const std = @import("std");
const name = @import("../name.zig");
const wire = @import("wire.zig");

/// What the caller sent: the frames the peer echoes must name all of it.
pub const Sent = struct { nonce: name.Id, operation: name.Id, proof: wire.Proof };

/// What the peer proved through its own pinned handles: the durable intent's
/// nonce and names, both roots as that intent recorded them, and the digests
/// of the bytes it read.
pub const Proved = struct { nonce: name.Id, from: []const u8, to: []const u8, source: []const u8, target: []const u8, proof: wire.Proof };

/// Peer, before it pins anything the request names.
pub fn frame(request: wire.Request) !void {
    if (request.version != wire.version or !name.isId(&request.nonce) or !name.isId(&request.operation)) return error.BadFrame;
    try (wire.Bounds{ .ready = request.ready_ms, .commit = request.commit_ms, .drain = request.drain_ms }).check();
    _ = try name.component(request.from);
    _ = try name.component(request.to);
}

/// Peer, once pinned: the request names exactly the intent it proved.
pub fn bound(request: wire.Request, proved: Proved) !void {
    if (!std.mem.eql(u8, &request.nonce, &proved.nonce) or !std.mem.eql(u8, request.from, proved.from) or !std.mem.eql(u8, request.to, proved.to)) return error.IdentityConflict;
    if (!std.mem.eql(u8, request.source.path, proved.source) or !std.mem.eql(u8, request.target.path, proved.target)) return error.IdentityConflict;
    if (!std.meta.eql(request.proof, proved.proof)) return error.IdentityConflict;
}

/// Peer: a COMMIT is honored only for this request's own exchange and proof.
pub fn commit(request: wire.Request, value: wire.Commit) !void {
    if (value.version != wire.version or !std.mem.eql(u8, &request.nonce, &value.nonce) or !std.mem.eql(u8, &request.operation, &value.operation) or !std.meta.eql(request.proof, value.proof)) return error.BadFrame;
    if (!value.commit) return error.Aborted;
}

/// Caller: a reply belongs to the exchange it sent and the phase it awaits.
pub fn reply(sent: Sent, value: wire.Reply, phase: wire.Phase) !void {
    if (value.version != wire.version or value.phase != phase or value.pid == 0 or value.birth == 0) return error.BadFrame;
    if (!std.mem.eql(u8, &sent.nonce, &value.nonce) or !std.mem.eql(u8, &sent.operation, &value.operation) or !std.meta.eql(sent.proof, value.proof)) return error.BadFrame;
    if (phase != .done and value.status != .success) return error.BadFrame;
}

/// Caller: the done reply comes from the same peer over the same pins.
pub fn pair(ready: wire.Reply, done: wire.Reply) !void {
    if (done.pid != ready.pid or done.birth != ready.birth or done.source_inode != ready.source_inode or done.source_root != ready.source_root or done.target_root != ready.target_root) return error.BadFrame;
}
