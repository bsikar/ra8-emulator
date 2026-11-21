//! Covers host input delivery to the console channel's receive register.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const sci = ra8.chip.periph.sci;
const input = ra8.chip.periph.sci.input;
const host_bytes = cli_app.cli.host.bytes;

/// Writes all of `bytes` to a pipe end, as the host side of the test.
fn send(fd: std.posix.fd_t, bytes: []const u8) !void {
    const end: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try end.writeStreamingAll(std.testing.io, bytes);
}

test "host input waiting on stdin reaches console SCI receive" {
    const fds = try ra8.host.pipe_pair.create(.{});
    defer ra8.host.read.close(fds[0]);
    defer ra8.host.read.close(fds[1]);

    try send(fds[1], "hi");
    var unit = sci.Sci.init();
    unit.write(sci.regAddress(sci.console_channel, sci.off_ccr0), 4, sci.ccr0.te | sci.ccr0.re);
    var reader: input.Input = .{ .source = host_bytes.of(fds[0]) };
    reader.poll(&unit);

    const rdr = sci.regAddress(sci.console_channel, sci.off_rdr);
    try std.testing.expectEqual(@as(u32, 'h'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 'i'), unit.read(rdr, 4));
    try std.testing.expectEqual(@as(u32, 2), unit.console().received);
}

const Held = struct {
    var on: bool = true;
    var fed: u32 = 0;
    var reads: u32 = 0;
    fn held(_: *anyopaque) bool {
        return on;
    }
    fn feed(_: *anyopaque, _: []const u8) void {
        fed += 1;
    }
    fn read(_: usize, _: []u8) ?usize {
        reads += 1;
        return null;
    }
};

test "while the host is held nothing is read from stdin and a due reply is retired, not typed" {
    var unit = sci.Sci.init();
    var token: u8 = 0;
    var reader: input.Input = .{ .source = .{ .context = 0, .readFn = Held.read } };
    reader.hook = .{ .context = &token, .feedFn = Held.feed, .heldFn = Held.held };
    reader.reply.due = true;
    Held.on = true;
    reader.poll(&unit);
    try std.testing.expectEqual(@as(u32, 0), Held.reads);
    try std.testing.expectEqual(@as(u32, 0), Held.fed);
    try std.testing.expect(!reader.reply.due and reader.reply.sent);
    Held.on = false;
    reader.poll(&unit);
    try std.testing.expectEqual(@as(u32, 1), Held.reads);
}

const Sink = struct {
    buf: [16]u8 = undefined,
    len: usize = 0,

    pub fn pushRx(self: *Sink, ch: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = ch;
            self.len += 1;
        }
    }
};

test "pollPush delivers due reply and stdin bytes to generic receiver" {
    const fds = try ra8.host.pipe_pair.create(.{});
    defer ra8.host.read.close(fds[0]);
    defer ra8.host.read.close(fds[1]);

    try send(fds[1], "ab");
    var sink: Sink = .{};
    var reader: input.Input = .{
        .source = host_bytes.of(fds[0]),
        .reply = .{ .text = "ok", .due = true },
    };
    reader.pollPush(&sink);

    try std.testing.expectEqualStrings("ok\nab", sink.buf[0..sink.len]);
    try std.testing.expect(reader.reply.sent and !reader.reply.due);
}
