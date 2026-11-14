const std = @import("std");
const ra8 = @import("ra8");
const wire = ra8.rpc.build_wire;
const io = std.testing.io;

const Sink = struct {
    chunks: usize = 0,
    completions: usize = 0,
    pub fn emit(self: *Sink, comptime T: type, topic: u16, value: T, _: []u8) !void {
        if (T == wire.Event) {
            try std.testing.expectEqual(wire.event_topic, topic);
            try std.testing.expectEqual(@as(usize, 0), self.completions);
            try std.testing.expectEqualStrings("tail", value.bytes);
            self.chunks += 1;
        } else {
            try std.testing.expectEqual(wire.completed_topic, topic);
            try std.testing.expectEqual(@as(usize, 1), self.chunks);
            try std.testing.expectEqual(@as(u8, 1), value.done);
            self.completions += 1;
        }
    }
};

test "build connection ownership refuses guessed IDs and emits all queued output before one completion" {
    if (!ra8.host.build.process.supported) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const compiler = if (@import("builtin").os.tag == .windows) "C:/ra8-no-such-compiler/zig.exe" else "/ra8-no-such-compiler/zig";
    var runner = try ra8.host.build.Runner.init(io, tmp.dir, compiler);
    defer runner.clear();
    var owner: ra8.rpc.session.server.Context = .{ .session = undefined, .scratch = &.{}, .build_runner = &runner };
    var other: ra8.rpc.session.server.Context = .{ .session = undefined, .scratch = &.{}, .build_runner = &runner };
    const id = ra8.rpc.build.start(&owner, .{ .step = "", .options = "[]", .artifact = "", .timeout_ms = 5000 }).ok.id;
    try std.testing.expectEqual(wire.codes.unknown_job, @backingInt(ra8.rpc.build.cancel(&other, .{ .id = id }).err));
    ra8.rpc.build.forget(&other);
    const job = try runner.get(id);
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + 5_000_000_000;
    while (!job.done.load(.acquire)) {
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.BuildDidNotFinish;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    const status = ra8.rpc.build.status(&owner, .{ .id = id }).ok;
    try std.testing.expectEqual(@as(u16, 2), @backingInt(ra8.rpc.build.start(&owner, .{ .step = "--help", .options = "[]", .artifact = "", .timeout_ms = 5000 }).err));
    try std.testing.expectEqual(id, (try runner.get(id)).id);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, status.result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("failed", parsed.value.object.get("state").?.string);
    try std.testing.expectEqualStrings("not_started", parsed.value.object.get("cleanup").?.string);
    try std.testing.expectEqualStrings("", parsed.value.object.get("artifact").?.string);
    job.queue.push(io, .stdout, "tail");
    var sink: Sink = .{};
    try ra8.rpc.build.pump(&owner, &sink, &.{});
    try ra8.rpc.build.pump(&owner, &sink, &.{});
    try std.testing.expectEqual(@as(usize, 1), sink.completions);
    ra8.rpc.build.forget(&owner);
    try std.testing.expect(runner.job == null);
    try std.testing.expectEqual(@as(u64, 0), owner.build_id);
}
