//! gdb's interrupt: a session with a poll runs budget after budget until
//! the poll says to halt, gdb reads that halt as T02, and the socket poll
//! takes an interrupt byte while leaving any other byte for the reader.
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const script = ra8.core.script;
const session = ra8.core.debug_session;
const stop_machine = ra8.core.stop_machine;
const step_hook = ra8.core.step_hook;
const rsp_dispatch = ra8.core.rsp_dispatch;
const Engine = ra8.core.engine.Engine;

const base: u32 = memmap.sram_base;
// Two nops, then a branch to self: a run that never stops on its own.
const program = [_]u8{ 0x00, 0xbf, 0x00, 0xbf, 0xfe, 0xe7 };

/// Says to halt on the `after`th time it is asked.
const Countdown = struct {
    asked: u32 = 0,
    after: u32,

    fn poll(self: *Countdown) session.Poll {
        return .{ .context = self, .check = check };
    }

    fn check(context: *anyopaque) bool {
        const self: *Countdown = @ptrCast(@alignCast(context));
        self.asked += 1;
        return self.asked >= self.after;
    }
};

const Fixture = struct {
    core: Engine,
    machine: stop_machine.Machine = .{},
    driver: step_hook.Driver = undefined,

    fn open(self: *Fixture) !void {
        self.machine = .{};
        self.core = try Engine.open();
        errdefer self.core.close();
        try self.core.mapBoardRam();
        try self.core.write(base, &program);
        self.driver = .{ .machine = &self.machine };
        try step_hook.attach(self.core.handle, &self.driver, false);
    }
};

test "a run with a poll keeps going past its budget until the poll halts it" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.core.close();
    var countdown = Countdown{ .after = 3 };
    var target = session.Session{ .core = &fixture.core, .driver = &fixture.driver, .entry = base, .budget = 50, .poll = countdown.poll() };
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    _ = try script.play(&target, "run", out.writer(), false);
    try std.testing.expectEqual(@as(u32, 3), countdown.asked);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Halted, ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Budget") == null);
    try std.testing.expectEqual(stop_machine.Stop.halt_requested, fixture.driver.last.?);
}

test "gdb's continue answers T02 when the interrupt halts it" {
    var fixture: Fixture = undefined;
    try fixture.open();
    defer fixture.core.close();
    var countdown = Countdown{ .after = 2 };
    var target = session.Session{ .core = &fixture.core, .driver = &fixture.driver, .entry = base, .budget = 50, .poll = countdown.poll() };
    const stub = rsp_dispatch.Dispatch{ .core = &fixture.core, .session = &target };
    var reply: [rsp_dispatch.packet_size]u8 = undefined;
    try std.testing.expectEqualStrings("T02thread:1;", try stub.answer("c", &reply));
    try std.testing.expectEqualStrings("T02thread:1;", try stub.answer("?", &reply));
}

test "the socket poll takes 0x03 and leaves any other byte unread" {
    const loopback = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try loopback.listen(.{ .reuse_address = true });
    defer server.deinit();
    const client = try std.net.tcpConnectToAddress(server.listen_address);
    defer client.close();
    const connection = try server.accept();
    defer connection.stream.close();
    var socket = rsp_dispatch.poll.Socket{ .handle = connection.stream.handle };
    const poll = socket.poll();
    try std.testing.expect(!poll.check(poll.context));
    try client.writeAll("+");
    try arrived(connection.stream.handle);
    try std.testing.expect(!poll.check(poll.context));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try connection.stream.read(&byte));
    try std.testing.expectEqual(@as(u8, '+'), byte[0]);
    try client.writeAll(&.{0x03});
    try arrived(connection.stream.handle);
    try std.testing.expect(poll.check(poll.context));
    try std.testing.expect(!poll.check(poll.context));
}

/// Wait up to a second for bytes on `handle`, so a check never races the
/// loopback delivery.
fn arrived(handle: std.posix.socket_t) !void {
    var fds = [_]std.posix.pollfd{.{ .fd = handle, .events = std.posix.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), try std.posix.poll(&fds, 1000));
}
