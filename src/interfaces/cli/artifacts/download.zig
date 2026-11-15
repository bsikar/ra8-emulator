//! Publish only a complete checksum-verified download, preserving an existing destination.
const std = @import("std");

const Client = @import("../ctl/client.zig").Client;
const proto = @import("ra8_rpc").session.rpc;
const wire = @import("ra8_rpc").artifacts.wire;

pub fn save(gpa: std.mem.Allocator, client: *Client, path: []const u8, recording: bool) !void {
    const descriptor = try client.callCode(wire.Descriptor, wire.Export, @backingInt(wire.Method.export_begin), .{
        .recording = @intFromBool(recording),
    });
    if (descriptor.total == 0 or descriptor.total > wire.max_bundle or descriptor.sha256.len != 32) {
        return error.BadReply;
    }
    const digest = descriptor.sha256[0..32].*;
    var tag: [16]u8 = undefined;
    client.io.random(&tag);
    const temporary = try std.fmt.allocPrint(gpa, "{s}.{x}.partial", .{ path, tag });
    defer gpa.free(temporary);
    const dir = std.Io.Dir.cwd();
    const file = try dir.createFile(client.io, temporary, .{ .exclusive = true });
    var closed = false;
    defer if (!closed) file.close(client.io);
    defer dir.deleteFile(client.io, temporary) catch |err| {
        if (err != error.FileNotFound) std.log.warn("artifact temporary cleanup: {s}", .{@errorName(err)});
    };
    try receive(client, descriptor, file, digest);
    try file.sync(client.io);
    file.close(client.io);
    closed = true;
    _ = try client.callCode(proto.Ack, wire.Id, @backingInt(wire.Method.abort), .{ .id = descriptor.id });
    try dir.renamePreserve(temporary, dir, path, client.io);
}

fn receive(client: *Client, descriptor: wire.Descriptor, file: std.Io.File, expected: [32]u8) !void {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var offset: u64 = 0;
    while (offset < descriptor.total) {
        const chunk = try client.callCode(wire.Chunk, wire.Read, @backingInt(wire.Method.export_read), .{
            .id = descriptor.id,
            .offset = offset,
            .length = wire.max_chunk,
        });
        if (chunk.id != descriptor.id or chunk.offset != offset or chunk.bytes.len == 0 or
            chunk.bytes.len > descriptor.total - offset) return error.BadReply;
        try file.writePositionalAll(client.io, chunk.bytes, offset);
        hash.update(chunk.bytes);
        offset += chunk.bytes.len;
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    if (!std.mem.eql(u8, &digest, &expected)) return error.BadChecksum;
}
