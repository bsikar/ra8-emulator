//! Host listener discovery, served RPC, GDB and reconnect tests (RA8EMU-1156).
//! They use the same Served context as the panes and real host sockets.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const serve_peer = @import("../cli/serve_peer.zig");
const slow_peer = @import("slow_peer.zig");
const listener_mod = ra8.rpc.host_listener;
const Connection = ra8.rpc.socket_transport.Connection;
const served_setup = ra8.rpc.served_setup;
const proto = ra8.rpc.session.rpc;

const image = serve_peer.image_path;
const Env = proto.Client.Env;

/// A fresh home under /tmp for one test.
fn tempHome(gpa: std.mem.Allocator) ![]u8 {
    var prng = std.Random.DefaultPrng.init(@intCast(std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds()));
    const parent = if (@import("builtin").os.tag == .windows)
        try (std.process.Environ{ .block = .global }).getAlloc(gpa, "TEMP")
    else
        try gpa.dupe(u8, "/tmp");
    defer gpa.free(parent);
    const name = try std.fmt.allocPrint(gpa, "ra8_listener_{d}", .{prng.random().int(u64)});
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ parent, name });
    errdefer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);
    return path;
}

fn envWithHome(gpa: std.mem.Allocator, home: []const u8) !std.process.Environ.Map {
    var env = std.process.Environ.Map.init(gpa);
    errdefer env.deinit();
    try env.put("HOME", home);
    return env;
}

test "the discovery file lists the rpc address and the sessions" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);

    const port = try bound.addGdb("/some/image.elf", null);
    try bound.announce();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}", .{bound.discovery_path});
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(4096));
    defer gpa.free(text);

    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, "\n"), '\n');
    const rpc_line = lines.next().?;
    const spec = try cli_app.serve.listen.Spec.parse(rpc_line["rpc ".len..]);
    switch (bound.address) {
        .unix => |path_name| try std.testing.expectEqualStrings(path_name, spec.unix),
        .tcp => |address| {
            try std.testing.expect(spec.tcp.eql(&address));
            try std.testing.expect(bound.socket_path == null);
        },
    }
    var port_buf: [32]u8 = undefined;
    const port_line = try std.fmt.bufPrint(&port_buf, "session {d} /some/image.elf", .{port});
    try std.testing.expectEqualStrings(port_line, lines.next().?);
    try std.testing.expect(std.mem.startsWith(u8, lines.next().?, "focus "));
    try std.testing.expectEqual(@as(?[]const u8, null), lines.next());

    bound.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(16)));
}

test "a client over the socket is served on the opened session" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    defer connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();

    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    try std.testing.expectEqual(proto.capabilities, (try next(peer, &bound, &opened.context, tx)).ready);
    try loadAndRead(peer, &bound, &opened.context, tx);
}

test "a client's subscriptions stay off the panes' context" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    _ = try next(peer, &bound, &opened.context, tx);

    // The client subscribes to the uart topic over the wire and gets its
    // own feed; the panes' context keeps none and no topics (RA8EMU-1196).
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .uart });
    try std.testing.expect(bound.client.?.context.uart_feed != null);
    try std.testing.expectEqual(@as(?usize, null), opened.context.uart_feed);
    try std.testing.expectEqual(@as(u8, 0), opened.context.topics[0]);

    // Hanging up releases the client's feed; the panes' context is untouched.
    connection.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client == null);
    try std.testing.expectEqual(@as(?usize, null), opened.context.uart_feed);
}

test "a hung-up client is dropped and the next one is taken" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var first = try connect(bound.address);
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client != null);
    first.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client == null);

    var second = try connect(bound.address);
    defer second.close();
    try bound.answer(&opened.context, tx);
    try std.testing.expect(bound.client != null);
}

test "a gdb client breaks, continues, hits it and reads registers" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null);
    defer opened.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();
    const port = try bound.addGdb(image, opened.context.session);

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    defer connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    try std.testing.expectEqual(proto.capabilities, (try next(peer, &bound, &opened.context, tx)).ready);

    // Load, run a budget and pause, so the core sits at a known pc.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, peer.gpa, .limited(1 << 20));
    defer peer.gpa.free(bytes);
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = bytes });
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 1000 });
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
    const pc0 = try call(peer, &bound, &opened.context, tx, proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    try std.testing.expect(pc0.value != 0);

    var gdb: Gdb = undefined;
    try gdb.init(port);
    defer gdb.deinit();

    // pc() sends a register read and parses the reply in target order.
    try std.testing.expectEqual(pc0.value, try gdb.pc(&bound));

    // Continuing from this breakpoint delivers the hit's stop reply.
    var point: [32]u8 = undefined;
    const where = try std.fmt.bufPrint(&point, "Z0,{x},1", .{pc0.value});
    try gdb.send(where);
    try std.testing.expectEqualStrings("OK", try gdb.reply(&bound));
    try gdb.send("c");
    const stop = try gdb.reply(&bound);
    try std.testing.expect(stop.len > 0 and (stop[0] == 'T' or stop[0] == 'S'));
    try std.testing.expectEqual(pc0.value, try gdb.pc(&bound));

    // The IDE's reset halt reboots from the ELF and pauses at its vector.
    const halt = try monitorHex(gpa, "reset halt");
    defer gpa.free(halt);
    try gdb.send(halt);
    try std.testing.expectEqualStrings("OK", try gdb.reply(&bound));
    const pc1 = try gdb.pc(&bound);
    try std.testing.expect(pc1 != pc0.value);
    const reload = try monitorHex(gpa, "reload");
    defer gpa.free(reload);
    try gdb.send(reload);
    try std.testing.expectEqualStrings("OK", try gdb.reply(&bound));
    try std.testing.expectEqual(pc1, try gdb.pc(&bound));

    // A monitor reply to a peer that stopped reading drops the client.
    const host = bound.gdb.items[0];
    try slow_peer.block(host.client.?.stream);
    try gdb.send("qRcmd,");
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 2000;
    while (host.client != null and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) bound.pumpGdb();
    try std.testing.expect(host.client == null);
}

test "ctl's discovery reader reads what the app announced" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    const ctl = cli_app.ctl;

    // No file, no app.
    try std.testing.expectEqual(@as(?ctl.discovery.Snapshot, null), try ctl.discovery.read(gpa, std.testing.io, &env));

    var file_path = std.ArrayList(u8).empty;
    defer file_path.deinit(gpa);
    try file_path.appendSlice(gpa, home);
    try file_path.appendSlice(gpa, "/.config/ra8_emulator");
    try std.Io.Dir.cwd().createDirPath(std.testing.io, file_path.items);
    try file_path.appendSlice(gpa, "/discovery");
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = file_path.items, .data = "rpc unix:/tmp/rpc.sock\nsession 4113 /work/blink.elf\nsession 5222 /work/my fw.elf\nfocus unix:/tmp/focus.sock\n" });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const snapshot = (try ctl.discovery.read(arena_state.allocator(), std.testing.io, &env)).?;
    try std.testing.expectEqualStrings("unix:/tmp/rpc.sock", snapshot.rpc);
    try std.testing.expectEqual(@as(usize, 2), snapshot.sessions.len);
    try std.testing.expectEqual(@as(u16, 4113), snapshot.sessions[0].port);
    try std.testing.expectEqualStrings("/work/blink.elf", snapshot.sessions[0].elf);
    // An ELF with a space survives the line split.
    try std.testing.expectEqualStrings("/work/my fw.elf", snapshot.sessions[1].elf);
}

/// One gdb client over the session's loopback port, pumped between frames.
const Gdb = struct {
    stream: std.Io.net.Stream,
    wire: ra8.gdb.rsp.packet.Reader,
    incoming: [0x1000]u8,
    reply_buf: [0x1000]u8,

    /// Fill in place: the reader holds the buffers' addresses.
    fn init(self: *Gdb, port: u16) !void {
        self.stream = try slow_peer.connect(port);
        errdefer self.stream.close(std.testing.io);
        self.wire = ra8.gdb.rsp.packet.Reader.init(&self.incoming);
    }

    fn deinit(self: *Gdb) void {
        self.stream.close(std.testing.io);
    }

    /// Frame and write one request.
    fn send(self: *Gdb, payload: []const u8) !void {
        var framed: [0x1100]u8 = undefined;
        const bytes = try ra8.gdb.rsp.packet.frame(&framed, payload);
        ra8.host.sock.ready.sendAll(std.testing.io, self.stream.socket.handle, bytes, 1000) catch return error.Socket;
    }

    /// The next packet the stub sends, pumping the host between polls.
    fn reply(self: *Gdb, bound: *listener_mod.Listener) ![]const u8 {
        const fd = self.stream.socket.handle;
        const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
        while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
            bound.pumpGdb();
            while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline and
                (ra8.host.sock.ready.wait(std.testing.io, fd, 0) catch return error.Socket).any())
            {
                var byte: [1]u8 = undefined;
                const got = ra8.host.sock.ready.takeByte(std.testing.io, fd, &byte, false) orelse return error.Socket;
                if (got == 0) return error.Closed;
                if (self.wire.push(byte[0])) |event| switch (event) {
                    .packet => |packet| {
                        @memcpy(self.reply_buf[0..packet.len], packet);
                        return self.reply_buf[0..packet.len];
                    },
                    else => {},
                };
            }
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.NoReply;
    }

    /// The pc as gdb reads it: register 15 through the `p` packet. rsp
    /// sends a register's bytes in target order, hex-encoded.
    fn pc(self: *Gdb, bound: *listener_mod.Listener) !u32 {
        try self.send("pf");
        const hex = try self.reply(bound);
        if (hex.len < 8) return error.ShortReply;
        var bytes: [4]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, hex[0..8]) catch return error.BadHex;
        return std.mem.readInt(u32, &bytes, .little);
    }
};

/// A monitor command as the wire sees it: qRcmd, plus the hex text.
fn monitorHex(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try gpa.alloc(u8, "qRcmd,".len + text.len * 2);
    @memcpy(out[0.."qRcmd,".len], "qRcmd,");
    const hex_chars = "0123456789abcdef";
    for (text, 0..) |byte, at| {
        out["qRcmd,".len + at * 2] = hex_chars[byte >> 4];
        out["qRcmd,".len + at * 2 + 1] = hex_chars[byte & 0xf];
    }
    return out;
}

/// The next frame from the server, serving the listener between polls.
fn next(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8) !proto.Client.Incoming {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        if (try peer.client.poll(peer.tx)) |incoming| return incoming;
        try bound.answer(context, tx);
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.ServerSilent;
}

/// One call, its reply taken off the wire through `next`.
fn call(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8, comptime Reply: type, comptime Args: type, method: proto.Method, args: Args) !Reply {
    _ = try peer.client.call(Args, @backingInt(method), args, 0, peer.tx);
    while (true) switch (try next(peer, bound, context, tx)) {
        .response => |response| return switch (response.result) {
            .ok => |bytes| try proto.decode(Reply, bytes),
            .err => error.Refused,
        },
        else => {},
    };
}

/// Load the fixture over the wire, run, pause and read pc.
fn loadAndRead(peer: *serve_peer.Peer, bound: *listener_mod.Listener, context: *listener_mod.served.Context, tx: []u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, image, peer.gpa, .limited(1 << 20));
    defer peer.gpa.free(bytes);
    _ = try call(peer, bound, context, tx, proto.Ack, proto.Load, .load, .{ .core = .cpu0, .image = bytes });
    _ = try call(peer, bound, context, tx, proto.Ack, proto.Run, .run, .{ .core = .cpu0, .mode = .cont, .budget = 1000 });
    _ = try call(peer, bound, context, tx, proto.Ack, proto.CoreOnly, .pause, .{ .core = .cpu0 });
    const pc = try call(peer, bound, context, tx, proto.U32, proto.ReadRegister, .read_register, .{ .core = .cpu0, .register = .pc });
    try std.testing.expect(pc.value != 0);
}

test "a focus connection is taken once and the second launch hands off" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    try bound.announce();
    try std.testing.expect(!bound.takeFocus());
    // The second launch: read the discovery file, connect to the focus
    // address, exit. focusRunning does all three.
    try listener_mod.focusRunning(gpa, std.testing.io, &env);
    try std.testing.expect(bound.takeFocus());
    try std.testing.expect(!bound.takeFocus());

    // With no running app, focusRunning fails and the caller runs on.
    std.Io.Dir.cwd().deleteFile(std.testing.io, bound.discovery_path) catch {};
    try std.testing.expectError(error.NotRunning, listener_mod.focusRunning(gpa, std.testing.io, &env));
}

fn connect(address: listener_mod.Address) !Connection {
    return switch (address) {
        .unix => |path| Connection.unix(std.testing.io, path),
        .tcp => |ip| Connection.tcp(std.testing.io, ip),
    };
}

test "an async advance queues over the socket and completes on the transport topic" {
    const gpa = std.testing.allocator;
    const home = try tempHome(gpa);
    defer {
        std.Io.Dir.cwd().deleteTree(std.testing.io, home) catch {};
        gpa.free(home);
    }
    var env = try envWithHome(gpa, home);
    defer env.deinit();
    var opened: served_setup.Served = undefined;
    try opened.open(gpa, std.testing.io, image, null);
    defer opened.deinit();
    // The hosted shell binds the queued advance contract on (hosted.zig);
    // the test mirrors it so the listener's client sees bit 15.
    opened.context.transport_async = true;
    var bound = try listener_mod.Listener.bind(gpa, std.testing.io, &env);
    defer bound.deinit();

    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var connection = try connect(bound.address);
    defer connection.close();
    const peer = try serve_peer.Peer.init(gpa, connection.transport());
    defer peer.deinit();
    try peer.client.greet(peer.tx);
    try bound.answer(&opened.context, tx);
    const ready = try next(peer, &bound, &opened.context, tx);
    try std.testing.expect(ready.ready & proto.transport_cap != 0);

    try loadAndRead(peer, &bound, &opened.context, tx);
    _ = try call(peer, &bound, &opened.context, tx, proto.Ack, proto.Subscription, .subscribe, .{ .core = .cpu0, .topic = .transport });

    // The queued reply arrives without the connection blocking on the job,
    // and the completion lands on the transport topic: a TransportEvent with
    // finished = 1 carrying the queued advance's own span. The first pump
    // can finish the job before the reply is even read, so the drain
    // collects events from the queue call on and never swallows one.
    _ = try peer.client.call(proto.Advance, @backingInt(proto.Method.advance_async), .{ .core = .cpu0, .ns = 50_000_000 }, 0, peer.tx);
    var queued: ?proto.AdvanceQueued = null;
    var finished: ?proto.TransportEvent = null;
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while ((queued == null or finished == null) and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        switch (try next(peer, &bound, &opened.context, tx)) {
            .response => |response| queued = switch (response.result) {
                .ok => |bytes| try proto.decode(proto.AdvanceQueued, bytes),
                .err => return error.Refused,
            },
            .event => |event| {
                if (event.topic != @backingInt(proto.Topic.transport)) continue;
                const report = try proto.decode(proto.TransportEvent, event.payload);
                if (report.finished != 1) continue;
                try std.testing.expectEqual(@as(u8, @backingInt(proto.Core.cpu0)), @backingInt(report.core));
                finished = report;
            },
            else => {},
        }
    }
    const span = queued orelse return error.NoQueuedReply;
    try std.testing.expectEqual(@as(u64, 50_000_000), span.target_ns - span.from_ns);
    const done = finished orelse return error.NoFinishedEvent;
    try std.testing.expectEqual(span.from_ns, done.from_ns);
    try std.testing.expectEqual(span.target_ns, done.target_ns);
    try std.testing.expect(done.to_ns >= span.target_ns);
}
