//! Upload in order; the server admits the complete archive before replacing its session.
const std = @import("std");

const Client = @import("../ctl/client.zig").Client;
const proto = @import("ra8_rpc").session.rpc;
const spool = @import("ra8_rpc").artifacts.spool;
const wire = @import("ra8_rpc").artifacts.wire;

pub fn send(client: *Client, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().openFile(client.io, path, .{});
    defer file.close(client.io);
    const size = (try file.stat(client.io)).size;
    if (size == 0 or size > wire.max_bundle) return error.TooLarge;
    const digest = try spool.checksum(file, client.io);
    const id = try client.callCode(wire.Id, wire.Begin, @backingInt(wire.Method.import_begin), .{
        .total = size,
        .sha256 = &digest,
    });
    var buffer: [wire.max_chunk]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const bytes = buffer[0..@intCast(@min(buffer.len, size - offset))];
        if (try file.readPositionalAll(client.io, bytes, offset) != bytes.len) return error.SourceChanged;
        const ack = try client.callCode(proto.Ack, wire.Chunk, @backingInt(wire.Method.import_write), .{
            .id = id.id,
            .offset = offset,
            .bytes = bytes,
        });
        if (ack.accepted != 1) return error.Refused;
        offset += bytes.len;
    }
    const result = try client.callCode(wire.Commit, wire.Id, @backingInt(wire.Method.import_end), id);
    if (result.accepted != 1 or result.reconnect != 1) return error.BadReply;
}
