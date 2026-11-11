//! RA8EMU-768 and RA8EMU-1175 through the serve handlers and real TCP socket
//! RPC: bare-name snapshot/restore round-trips machine state, while path-escape
//! and malformed-snapshot requests return RPC errors with zero host escape and
//! zero mutation of live machine state.
const std = @import("std");
const ra8 = @import("ra8");

const api = ra8.session.api;
const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const files = ra8.rpc.session.files;
const Connection = ra8.rpc.socket_transport.Connection;
const sock_ready = ra8.host.sock.ready;
const memmap = ra8.chip.core.memmap;

const image = "tests/fixtures/uart/uart_irq_echo.elf";
/// A word in SRAM the fixture never touches, so it reads zero when saved.
const spare = memmap.sram_base + 0x0004_0000;
const host_ops = ra8.host.session_files.cwd(ra8.session.file_ops.Ops);
const all_regs = std.enums.values(api.Register);

fn runFor(harness: *ra8.session.harness.Harness, instructions: u64) !void {
    const session = harness.session();
    session.live.budget = instructions;
    _ = try session.run(.cpu0, .cont);
}

fn word(harness: *ra8.session.harness.Harness) !u32 {
    var bytes: [4]u8 = undefined;
    try harness.session().read(.cpu0, spare, &bytes);
    return std.mem.readInt(u32, &bytes, .little);
}

const Baseline = struct {
    gpa: std.mem.Allocator,
    regs: [all_regs.len]u32,
    sram_word: u32,
    pos: api.Position,
    now_ns: u64,
    snap_bytes: []u8,

    fn capture(gpa: std.mem.Allocator, h: *ra8.session.harness.Harness) !Baseline {
        var regs: [all_regs.len]u32 = undefined;
        for (all_regs, 0..) |reg, idx| {
            regs[idx] = try h.session().register(.cpu0, reg);
        }
        var out = std.Io.Writer.Allocating.init(gpa);
        errdefer out.deinit();
        try h.state.files.writeTo(&out.writer);
        const snap_bytes = try gpa.dupe(u8, out.written());
        out.deinit();
        return .{
            .gpa = gpa,
            .regs = regs,
            .sram_word = try word(h),
            .pos = h.session().currentPosition(),
            .now_ns = try h.session().now(),
            .snap_bytes = snap_bytes,
        };
    }

    fn deinit(self: *Baseline) void {
        self.gpa.free(self.snap_bytes);
    }

    fn expectMatches(self: *const Baseline, h: *ra8.session.harness.Harness) !void {
        for (all_regs, 0..) |reg, idx| {
            try std.testing.expectEqual(self.regs[idx], try h.session().register(.cpu0, reg));
        }
        try std.testing.expectEqual(self.sram_word, try word(h));
        try std.testing.expectEqual(self.pos, h.session().currentPosition());
        try std.testing.expectEqual(self.now_ns, try h.session().now());
        var cur = std.Io.Writer.Allocating.init(self.gpa);
        defer cur.deinit();
        try h.state.files.writeTo(&cur.writer);
        try std.testing.expectEqualSlices(u8, self.snap_bytes, cur.written());
    }
};

const Env = proto.Client.Env;

const SockRig = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    server_conn: Connection,
    client_conn: Connection,
    rx: [2][]u8,
    tx: []u8,
    client: proto.Client = undefined,
    host: server.Host = undefined,

    fn open(gpa: std.mem.Allocator, io: std.Io, context: *server.Context) !*SockRig {
        var listener = try (std.Io.net.IpAddress{ .ip4 = .loopback(0) }).listen(io, .{});
        defer listener.deinit(io);
        var client_conn = try Connection.tcp(io, listener.socket.address);
        errdefer client_conn.close();
        try std.testing.expect((try sock_ready.wait(io, listener.socket.handle, 1000)).any());
        var server_conn: Connection = .{ .stream = try listener.accept(io), .io = io };
        errdefer server_conn.close();

        const self = try gpa.create(SockRig);
        errdefer gpa.destroy(self);
        const rx0 = try gpa.alloc(u8, 2 * Env.max_frame);
        errdefer gpa.free(rx0);
        const rx1 = try gpa.alloc(u8, 2 * Env.max_frame);
        errdefer gpa.free(rx1);
        const tx = try gpa.alloc(u8, Env.max_frame);
        errdefer gpa.free(tx);

        self.* = .{
            .gpa = gpa,
            .io = io,
            .server_conn = server_conn,
            .client_conn = client_conn,
            .rx = .{ rx0, rx1 },
            .tx = tx,
        };
        self.client = proto.Client.init(self.client_conn.transport(), self.rx[0], proto.capabilities);
        self.host = server.Host.init(self.server_conn.transport(), self.rx[1], context);
        try self.handshake();
        return self;
    }

    fn handshake(self: *SockRig) !void {
        try self.client.greet(self.tx);
        try self.pumpHost(.greeted);
        var got_ready = false;
        for (0..32) |_| {
            if (try self.client.poll(self.tx)) |incoming| {
                try std.testing.expectEqual(proto.capabilities, incoming.ready);
                got_ready = true;
                break;
            }
            _ = try sock_ready.wait(self.io, self.client_conn.stream.socket.handle, 200);
        }
        try std.testing.expect(got_ready);
    }

    fn pumpHost(self: *SockRig, want: server.rpc_lib.Step) !void {
        for (0..32) |_| {
            const step = try self.host.poll(self.tx);
            if (step == want) return;
            try std.testing.expectEqual(server.rpc_lib.Step.idle, step);
            _ = try sock_ready.wait(self.io, self.server_conn.stream.socket.handle, 200);
        }
        return error.HostTimeout;
    }

    fn call(self: *SockRig, comptime Args: type, method: proto.Method, args: Args) !Env.Result {
        _ = try self.client.call(Args, @backingInt(method), args, 0, self.tx);
        try self.pumpHost(.answered);
        var result: ?Env.Result = null;
        for (0..32) |_| {
            while (try self.client.poll(self.tx)) |incoming| switch (incoming) {
                .response => |resp| result = resp.result,
                .event => {},
                .ready => return error.UnexpectedReady,
            };
            if (result) |done| return done;
            _ = try sock_ready.wait(self.io, self.client_conn.stream.socket.handle, 200);
        }
        return error.ClientTimeout;
    }

    fn deinit(self: *SockRig) void {
        self.client_conn.close();
        self.server_conn.close();
        for (self.rx) |buf| self.gpa.free(buf);
        self.gpa.free(self.tx);
        self.gpa.destroy(self);
    }
};

fn countDirEntries(io: std.Io, dir: std.Io.Dir) !usize {
    var iter_dir = try dir.openDir(io, ".", .{ .iterate = true });
    defer iter_dir.close(io);
    var count: usize = 0;
    var it = iter_dir.iterate();
    while (try it.next(io)) |_| count += 1;
    return count;
}

test "restore puts pc, guest memory and virtual time back where snapshot left them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = "run.ra8snap";

    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .state_dir = dir, .files = host_ops });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };

    try runFor(&opened, 20_000);
    const pc = try opened.session().register(.cpu0, .pc);
    const at = try opened.session().now();
    const kept = try word(&opened);
    try std.testing.expect(files.snapshot(&context, .{ .path = path }) == .ok);

    try runFor(&opened, 20_000);
    try opened.session().write(.cpu0, spare, &.{ 0xef, 0xbe, 0xad, 0xde });
    try std.testing.expect(try opened.session().now() > at);

    try std.testing.expect(files.restore(&context, .{ .path = path }) == .ok);
    try std.testing.expectEqual(pc, try opened.session().register(.cpu0, .pc));
    try std.testing.expectEqual(at, try opened.session().now());
    try std.testing.expectEqual(kept, try word(&opened));

    // The restored run carries on as the saved one did.
    try runFor(&opened, 20_000);
    try std.testing.expect(try opened.session().now() > at);
}

test "snapshot and restore are refused with no state hook or no such file" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .files = host_ops });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var bare: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try std.testing.expect(files.snapshot(&bare, .{ .path = "unused" }) == .err);
    var served: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };
    try std.testing.expect(files.restore(&served, .{ .path = "no-such.ra8snap" }) == .err);
}

test "snapshot and restore refuse every path that leaves the state directory (RA8EMU-1175)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);

    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image, .state_dir = dir, .files = host_ops });
    defer opened.deinit();
    var scratch: [64]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };

    for ([_][]const u8{ "/tmp/x.ra8snap", "../x.ra8snap", "a/b.ra8snap", "..", ".", "" }) |path| {
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().save(path));
        try std.testing.expectError(error.BadStatePath, opened.stateFiles().restore(path));
    }
    // A bare name lands in the state directory, and nothing the refusals
    // were offered was written anywhere.
    try std.testing.expect(files.snapshot(&context, .{ .path = "ok.state" }) == .ok);
    const landed = try std.fs.path.join(std.testing.allocator, &.{ dir, "ok.state" });
    defer std.testing.allocator.free(landed);
    try std.testing.expect((try tmp.dir.statFile(std.testing.io, "ok.state", .{})).kind == .file);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "../x.ra8snap", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "a/b.ra8snap", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "x.ra8snap", .{}));
}

test "socket RPC snapshot and restore round-trip full machine state over loopback TCP" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "states");
    const state_dir = try tmp.dir.realPathFileAlloc(io, "states", gpa);
    defer gpa.free(state_dir);

    var opened = try ra8.session.harness.open(gpa, io, .{ .elf_path = image, .state_dir = state_dir, .files = host_ops });
    defer opened.deinit();
    var scratch: [256]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };
    var rig = try SockRig.open(gpa, io, &context);
    defer rig.deinit();

    try runFor(&opened, 20_000);
    try opened.session().write(.cpu0, spare, &.{ 0xbe, 0xba, 0xfe, 0xca });
    var saved = try Baseline.capture(gpa, &opened);
    defer saved.deinit();

    const snap_res = try rig.call(proto.StatePath, .snapshot, .{ .path = "clean.ra8snap" });
    try std.testing.expect(snap_res == .ok);

    try runFor(&opened, 20_000);
    try opened.session().write(.cpu0, spare, &.{ 0xef, 0xbe, 0xad, 0xde });
    try opened.session().setRegister(.cpu0, .r0, 0x1234_5678);
    try std.testing.expect(try opened.session().now() > saved.now_ns);

    const rest_res = try rig.call(proto.StatePath, .restore, .{ .path = "clean.ra8snap" });
    try std.testing.expect(rest_res == .ok);
    try saved.expectMatches(&opened);
}

test "socket RPC refuses path escapes and malformed snapshots without host escape or state mutation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "states");
    var states_dir = try tmp.dir.openDir(io, "states", .{ .iterate = true });
    defer states_dir.close(io);
    const state_dir_path = try tmp.dir.realPathFileAlloc(io, "states", gpa);
    defer gpa.free(state_dir_path);

    var opened = try ra8.session.harness.open(gpa, io, .{ .elf_path = image, .state_dir = state_dir_path, .files = host_ops });
    defer opened.deinit();
    var scratch: [256]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch, .state = opened.stateFiles() };
    var rig = try SockRig.open(gpa, io, &context);
    defer rig.deinit();

    try runFor(&opened, 15_000);
    try std.testing.expect((try rig.call(proto.StatePath, .snapshot, .{ .path = "seed.ra8snap" })) == .ok);

    try runFor(&opened, 15_000);
    try opened.session().write(.cpu0, spare, &.{ 0xdf, 0x9b, 0x57, 0x13 });
    try opened.session().setRegister(.cpu0, .r1, 0x7788_99aa);
    var live = try Baseline.capture(gpa, &opened);
    defer live.deinit();

    const escapes = [_][]const u8{
        "../escape.snap",
        "..\\escape.snap",
        "nested/escape.snap",
        "nested\\escape.snap",
        "/tmp/escape.snap",
        "\\escape.snap",
        "C:\\escape.snap",
        "C:escape.snap",
        "..",
        ".",
        "",
        "bad\x00name.snap",
    };
    for (escapes) |bad| {
        const snap_reply = try rig.call(proto.StatePath, .snapshot, .{ .path = bad });
        try std.testing.expectEqual(@as(u16, proto.app_codes.refused), @backingInt(snap_reply.err));
        const rest_reply = try rig.call(proto.StatePath, .restore, .{ .path = bad });
        try std.testing.expectEqual(@as(u16, proto.app_codes.refused), @backingInt(rest_reply.err));
        try std.testing.expectEqual(@as(usize, 1), try countDirEntries(io, tmp.dir));
        try std.testing.expectEqual(@as(usize, 1), try countDirEntries(io, states_dir));
        try live.expectMatches(&opened);
    }

    const valid_bytes = try states_dir.readFileAlloc(io, "seed.ra8snap", gpa, .limited(16 << 20));
    defer gpa.free(valid_bytes);
    try writeBytes(io, states_dir, "empty.snap", "");
    try writeBytes(io, states_dir, "garbage.snap", "not-an-ra8-snapshot-at-all");
    try writeBytes(io, states_dir, "half.snap", valid_bytes[0 .. valid_bytes.len / 2]);
    try writeBytes(io, states_dir, "tail_cut.snap", valid_bytes[0 .. valid_bytes.len - 5]);

    for ([_][]const u8{ "missing.snap", "empty.snap", "garbage.snap", "half.snap", "tail_cut.snap" }) |bad_file| {
        const reply = try rig.call(proto.StatePath, .restore, .{ .path = bad_file });
        try std.testing.expectEqual(@as(u16, proto.app_codes.refused), @backingInt(reply.err));
        try live.expectMatches(&opened);
    }
}

fn writeBytes(io: std.Io, dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
    var f = try dir.createFile(io, name, .{});
    defer f.close(io);
    var buf: [1024]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
}
