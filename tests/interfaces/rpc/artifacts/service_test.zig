const std = @import("std");
const ra8 = @import("ra8");

const artifacts = ra8.rpc.artifacts;
const fixture = @import("fixture.zig");
const gpa = fixture.gpa;

fn ok(comptime T: type, result: anytype) !T {
    return switch (result) {
        .ok => |value| value,
        .err => error.Refused,
    };
}

test "export download and checked upload prepare a replacement before activation" {
    var f = try fixture.Fixture.open();
    defer f.close();
    const context = &f.original.context;
    const saved = try context.session.register(.cpu0, .r0);
    const descriptor = try ok(artifacts.wire.Descriptor, artifacts.handlers.exportBegin(context, .{ .recording = 0 }));
    try context.session.setRegister(.cpu0, .r0, saved +% 1);
    var bytes = std.Io.Writer.Allocating.init(gpa);
    defer bytes.deinit();
    while (bytes.written().len < descriptor.total) {
        const chunk = try ok(artifacts.wire.Chunk, artifacts.handlers.exportRead(context, .{ .id = descriptor.id, .offset = bytes.written().len, .length = artifacts.wire.max_chunk }));
        try bytes.writer.writeAll(chunk.bytes);
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes.written(), &digest, .{});
    try std.testing.expectEqualSlices(u8, descriptor.sha256, &digest);
    _ = try ok(ra8.rpc.session.rpc.Ack, artifacts.handlers.abort(context, .{ .id = descriptor.id }));
    const upload = try ok(artifacts.wire.Id, artifacts.handlers.importBegin(context, .{ .total = bytes.written().len, .sha256 = &digest }));
    var offset: usize = 0;
    while (offset < bytes.written().len) {
        const end = @min(offset + artifacts.wire.max_chunk, bytes.written().len);
        _ = try ok(ra8.rpc.session.rpc.Ack, artifacts.handlers.importWrite(context, .{ .id = upload.id, .offset = offset, .bytes = bytes.written()[offset..end] }));
        offset = end;
    }
    const commit = try ok(artifacts.wire.Commit, artifacts.handlers.importEnd(context, upload));
    try std.testing.expect(commit.reconnect != 0);
    try std.testing.expect(f.service.active == f.original);
    try std.testing.expectEqual(saved +% 1, try f.original.owner.session().register(.cpu0, .r0));
    f.service.activate();
    try std.testing.expect(f.service.active != f.original);
    try std.testing.expectEqual(saved, try f.service.active.owner.session().register(.cpu0, .r0));
}

test "RAM recording capture imports its root branches and checkpoint objects" {
    var f = try fixture.Fixture.open();
    defer f.close();
    const file = try artifacts.capture.make(f.original, f.service.spool, true);
    defer file.close(std.testing.io);
    try f.service.prepare(file);
    try std.testing.expect(f.service.pending.?.history != null);
    f.service.activate();
    const facts = try ra8.rpc.history_bridge.Bridge.facts(&f.service.active.bridge.?);
    try std.testing.expect(facts.checkpoints.len > 0);
}

test "queued transport work refuses capture and discarded admission preserves active ownership" {
    var f = try fixture.Fixture.open();
    defer f.close();
    const file = try artifacts.capture.make(f.original, f.service.spool, false);
    defer file.close(std.testing.io);
    try f.service.prepare(file);
    f.service.discardPending();
    try std.testing.expect(f.service.active == f.original);
    try std.testing.expect(f.service.pending == null);
    _ = try f.original.owner.transport().command(.{ .advance = .{ .core = .cpu0, .ns = 10 } });
    try std.testing.expectError(error.SessionBusy, artifacts.capture.make(f.original, f.service.spool, false));
    try std.testing.expectError(error.SessionBusy, f.service.prepare(file));
}

test "artifact discovery does not overlap baseline debugger capabilities" {
    const baseline = ra8.rpc.session.rpc.capabilities | ra8.rpc.session.rpc.transport_cap;
    try std.testing.expectEqual(@as(u32, 0), artifacts.wire.capability & baseline);
}
