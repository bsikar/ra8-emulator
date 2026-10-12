//! Covers the hang-up check in src/interfaces/cli/serve/loop.zig
//! (RA8EMU-1163) against real pipes: a pipe is closed once its writer is
//! gone and every byte it sent has been read. Linux polls that as HUP alone;
//! Darwin polls it as readable and HUP, with or without bytes left, which
//! is the case that used to spin `serve --stdio`.
const std = @import("std");
const ra8 = @import("ra8");
const host = ra8.host;
const served = ra8.rpc.session.server;
const Transport = served.rpc_lib.Transport;
const loop = @import("cli_app").serve.loop;

/// Writes all of `bytes` to a pipe end, as the client side of the test.
fn send(fd: std.posix.fd_t, bytes: []const u8) !void {
    const end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try end.writeStreamingAll(std.testing.io, bytes);
}

test "a pipe whose writer is still there is not closed" {
    const ends = try host.pipe_pair.create(.{});
    defer host.read.close(ends[0]);
    defer host.read.close(ends[1]);
    try std.testing.expect(!try loop.closed(std.testing.io, ends[0], .pipe));
    try send(ends[1], "ok");
    try std.testing.expect(!try loop.closed(std.testing.io, ends[0], .pipe));
}

test "bytes left behind a hung-up writer keep the pipe open until they are read" {
    const ends = try host.pipe_pair.create(.{});
    defer host.read.close(ends[0]);
    try send(ends[1], "ok");
    host.read.close(ends[1]);
    try std.testing.expect(!try loop.closed(std.testing.io, ends[0], .pipe));
    var bytes: [8]u8 = undefined;
    const file: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    var reader = file.reader(std.testing.io, &.{});
    try std.testing.expectEqual(@as(usize, 2), try reader.interface.readSliceShort(&bytes));
    try std.testing.expect(try loop.closed(std.testing.io, ends[0], .pipe));
}

test "a pipe whose writer hung up with nothing sent is closed" {
    const ends = try host.pipe_pair.create(.{});
    defer host.read.close(ends[0]);
    host.read.close(ends[1]);
    try std.testing.expect(try loop.closed(std.testing.io, ends[0], .pipe));
}

const FailedTransport = struct {
    failure: Transport.Error,
    receives: usize = 0,

    fn wire(self: *FailedTransport) Transport {
        return .{ .ctx = self, .vtable = &.{ .send = write, .receive = receive, .poll = poll } };
    }

    fn write(_: *anyopaque, _: []const u8) Transport.Error!void {
        return error.LinkDown;
    }

    fn receive(ctx: *anyopaque, _: []u8) Transport.Error!usize {
        const self: *FailedTransport = @ptrCast(@alignCast(ctx));
        self.receives += 1;
        return self.failure;
    }

    fn poll(_: *anyopaque) usize {
        return 1;
    }
};

fn answerFailure(fd: std.posix.fd_t, failure: Transport.Error) !void {
    // The failing receive never dispatches a frame or accesses the live core.
    var session: ra8.session.api.Session = .{ .live = undefined };
    var context: served.Context = .{ .session = &session, .scratch = &.{} };
    var rx: [2048]u8 = undefined;
    var tx: [2048]u8 = undefined;
    var failed: FailedTransport = .{ .failure = failure };
    const result = loop.answer(std.testing.io, &context, failed.wire(), fd, .pipe, .{ .rx = &rx, .tx = &tx });
    try std.testing.expectEqual(@as(usize, 1), failed.receives);
    return result;
}

fn drainedPipe() !std.posix.fd_t {
    const ends = try host.pipe_pair.create(.{});
    errdefer host.read.close(ends[0]);
    {
        defer host.read.close(ends[1]);
        try send(ends[1], "ok");
    }
    try std.testing.expect(!try loop.closed(std.testing.io, ends[0], .pipe));
    var bytes: [2]u8 = undefined;
    const file: std.Io.File = .{ .handle = ends[0], .flags = .{ .nonblocking = false } };
    var reader = file.reader(std.testing.io, &.{});
    try reader.interface.readSliceAll(&bytes);
    try std.testing.expectEqualStrings("ok", &bytes);
    try std.testing.expect(try loop.closed(std.testing.io, ends[0], .pipe));
    return ends[0];
}

test "drained closed pipe preserves non-LinkDown transport errors" {
    const fd = try drainedPipe();
    defer host.read.close(fd);
    try std.testing.expectError(error.BadMessage, answerFailure(fd, error.BadMessage));
    try std.testing.expectError(error.LinkFull, answerFailure(fd, error.LinkFull));
}

test "drained closed pipe completes normally after LinkDown" {
    const fd = try drainedPipe();
    defer host.read.close(fd);
    try answerFailure(fd, error.LinkDown);
}

test "pipe with a live writer preserves LinkDown" {
    const ends = try host.pipe_pair.create(.{});
    defer for (ends) |fd| host.read.close(fd);
    try std.testing.expectError(error.LinkDown, answerFailure(ends[0], error.LinkDown));
}
