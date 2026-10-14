//! Real subprocess evidence for the history lifecycle: a peer executable
//! holds a session's lease as a separate process, so the tests prove what
//! the kernel does with the lock across a stop, a kill, a clean exit and
//! a hangup, which no in-process simulation can substitute for.
const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const test_paths = @import("test_paths");

const io = std.testing.io;
const allocator = std.testing.allocator;

/// Linux signal numbers, kept as integers so the test compiles everywhere
/// and only the guarded call reaches the OS.
const signals = struct {
    const hangup: u8 = 1;
    const kill: u8 = 9;
    const stop: u8 = 19;
    const cont: u8 = 18;
};

const Roots = struct {
    tmp: std.testing.TmpDir,
    cache_path: []u8,
    kept_path: []u8,
    cache: history.base.Base,
    kept: history.base.Base,

    fn init() !Roots {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
        defer allocator.free(root);
        const cache_path = try std.fs.path.join(allocator, &.{ root, "cache" });
        errdefer allocator.free(cache_path);
        const kept_path = try std.fs.path.join(allocator, &.{ root, "kept" });
        errdefer allocator.free(kept_path);
        var cache = try history.base.Base.open(allocator, io, cache_path, .cache);
        errdefer cache.close();
        var kept = try history.base.Base.open(allocator, io, kept_path, .kept);
        errdefer kept.close();
        return .{ .tmp = tmp, .cache_path = cache_path, .kept_path = kept_path, .cache = cache, .kept = kept };
    }

    fn deinit(self: *Roots) void {
        self.kept.close();
        self.cache.close();
        self.tmp.cleanup();
        allocator.free(self.cache_path);
        allocator.free(self.kept_path);
    }
};

const Peer = struct {
    child: std.process.Child,
    id: history.name.Id = @splat('0'),
    killed: bool = false,
    reaped: bool = false,

    fn spawn(cache_path: []const u8, scenario: []const u8, id_char: u8, kept_path: ?[]const u8) !Peer {
        var id_byte: [1]u8 = .{id_char};
        var slots: [5][]const u8 = undefined;
        var argv: []const []const u8 = slots[0..4];
        slots[0] = test_paths.host_lifecycle_peer;
        slots[1] = cache_path;
        slots[2] = scenario;
        slots[3] = &id_byte;
        if (kept_path) |kept| {
            slots[4] = kept;
            argv = slots[0..5];
        }
        return .{ .child = try std.process.spawn(io, .{
            .argv = argv,
            .pgid = 0,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }) };
    }

    fn takeId(self: *Peer) !void {
        self.id = try readId(&self.child);
    }

    /// End the peer however it is still running, drain its stderr, and
    /// return its term. Idempotent after a kill.
    fn finish(self: *Peer) !std.process.Child.Term {
        if (!self.killed) {
            if (self.child.stdin) |stdin| stdin.close(io);
            self.child.stdin = null;
        }
        var buffer: [4096]u8 = undefined;
        while (true) {
            const read = std.posix.read(self.child.stderr.?.handle, &buffer) catch break;
            if (read == 0) break;
        }
        self.reaped = true;
        return self.child.wait(io);
    }

    fn kill(self: *Peer, signal: u8) !void {
        switch (builtin.os.tag) {
            .linux => try std.posix.kill(self.child.id.?, @fromBackingInt(@intCast(signal))),
            else => {},
        }
    }

    fn deinit(self: *Peer) void {
        if (!self.reaped) {
            if (self.child.id) |pid| {
                std.posix.kill(pid, .KILL) catch {};
                _ = self.child.wait(io) catch {};
            }
        }
    }
};

fn readId(child: *std.process.Child) !history.name.Id {
    var line: [history.name.id_len + 1]u8 = undefined;
    try readExactly(child, &line);
    if (line[line.len - 1] != '\n') return error.BadIdLine;
    return line[0..history.name.id_len].*;
}

fn readOutcome(child: *std.process.Child) !history.session.Outcome {
    var line: [16]u8 = undefined;
    var got: usize = 0;
    while (got < line.len) {
        const read = std.posix.read(child.stdout.?.handle, line[got..]) catch break;
        if (read == 0) break;
        got += read;
        if (line[got - 1] == '\n') break;
    }
    if (got == 0 or line[got - 1] != '\n') return error.BadOutcomeLine;
    return std.meta.stringToEnum(history.session.Outcome, std.mem.trim(u8, line[0 .. got - 1], " ")) orelse error.BadOutcomeLine;
}

fn readExactly(child: *std.process.Child, buffer: []u8) !void {
    var got: usize = 0;
    while (got < buffer.len) {
        const read = try std.posix.read(child.stdout.?.handle, buffer[got..]);
        if (read == 0) return error.PeerEnded;
        got += read;
    }
}

fn presentId(base: *const history.base.Base, id: *const history.name.Id) !bool {
    base.dir.access(io, id, .{}) catch |err| return if (err == error.FileNotFound) false else err;
    return true;
}

fn sweep(base: *const history.base.Base) !history.sweep.Report {
    return history.sweep.run(base, .{}, null);
}

fn expectExited(term: std.process.Child.Term, code: u8) !void {
    switch (term) {
        .exited => |exit| try std.testing.expectEqual(code, exit),
        else => return error.UnexpectedTerm,
    }
}

fn expectSignalled(term: std.process.Child.Term, signal: u8) !void {
    switch (term) {
        .signal => |got| try std.testing.expectEqual(signal, @backingInt(got)),
        else => return error.UnexpectedTerm,
    }
}

test "host lifecycle subprocess kill-9 is swept at the next start" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var peer = try Peer.spawn(roots.cache_path, "hold", 'a', null);
    defer peer.deinit();
    try peer.takeId();
    try peer.kill(signals.kill);
    peer.killed = true;
    try expectSignalled(try peer.finish(), signals.kill);
    const report = try sweep(&roots.cache);
    try std.testing.expectEqual(@as(u64, 1), report.removed);
    try std.testing.expectEqual(@as(u64, 0), report.protected);
    try std.testing.expect(!try presentId(&roots.cache, &peer.id));
}

test "host lifecycle subprocess a stopped holder keeps its lease" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var peer = try Peer.spawn(roots.cache_path, "hold", 'b', null);
    defer peer.deinit();
    try peer.takeId();
    try std.testing.expectEqual(history.lock.State.held, history.lock.probe(io, roots.cache.dir, &peer.id));
    try peer.kill(signals.stop);
    const held = try sweep(&roots.cache);
    try std.testing.expectEqual(@as(u64, 0), held.removed);
    try std.testing.expectEqual(@as(u64, 1), held.protected);
    try std.testing.expect(try presentId(&roots.cache, &peer.id));
    try peer.kill(signals.cont);
    try peer.kill(signals.kill);
    peer.killed = true;
    try expectSignalled(try peer.finish(), signals.kill);
    const swept = try sweep(&roots.cache);
    try std.testing.expectEqual(@as(u64, 1), swept.removed);
    try std.testing.expect(!try presentId(&roots.cache, &peer.id));
}

test "host lifecycle subprocess concurrent starts agree on one name" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var first = try Peer.spawn(roots.cache_path, "hold", 'c', null);
    defer first.deinit();
    var second = try Peer.spawn(roots.cache_path, "hold", 'c', null);
    defer second.deinit();
    var winner: ?*Peer = null;
    var loser: ?*Peer = null;
    for ([_]*Peer{ &first, &second }) |peer| {
        const got = try readIdOrNothing(&peer.child);
        if (got != null) {
            if (winner != null) return error.TwoWinners;
            peer.id = got.?;
            winner = peer;
        } else {
            if (loser != null) return error.TwoLosers;
            loser = peer;
        }
    }
    const held = winner orelse return error.NoWinner;
    try std.testing.expectEqual(history.lock.State.held, history.lock.probe(io, roots.cache.dir, &held.id));
    if (loser) |ended| {
        const term = try ended.finish();
        switch (term) {
            .exited => |exit| try std.testing.expect(exit != 0),
            else => {},
        }
    }
    try held.kill(signals.kill);
    held.killed = true;
    try expectSignalled(try held.finish(), signals.kill);
    const report = try sweep(&roots.cache);
    try std.testing.expectEqual(@as(u64, 1), report.removed);
}

fn readIdOrNothing(child: *std.process.Child) !?history.name.Id {
    var line: [history.name.id_len + 1]u8 = undefined;
    var got: usize = 0;
    while (got < line.len) {
        const read = std.posix.read(child.stdout.?.handle, line[got..]) catch break;
        if (read == 0) break;
        got += read;
    }
    if (got == 0) return null;
    if (line[line.len - 1] != '\n') return error.BadIdLine;
    return line[0..history.name.id_len].*;
}

test "host lifecycle subprocess a wrong-host entry is only listed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var peer = try Peer.spawn(roots.cache_path, "hold", 'd', null);
    defer peer.deinit();
    try peer.takeId();
    try peer.kill(signals.kill);
    peer.killed = true;
    try expectSignalled(try peer.finish(), signals.kill);
    var dir = try roots.cache.dir.openDir(io, &peer.id, .{ .iterate = true });
    defer dir.close(io);
    try dir.deleteFile(io, history.layout.files.owner);
    try history.owner.write(io, dir, .{ .host = "ra8-elsewhere.example" });
    const report = try sweep(&roots.cache);
    try std.testing.expectEqual(@as(u64, 1), report.other_hosts);
    try std.testing.expectEqual(@as(u64, 0), report.removed);
    try std.testing.expect(try presentId(&roots.cache, &peer.id));
}

test "host lifecycle subprocess a clean exit leaves zero session bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var peer = try Peer.spawn(roots.cache_path, "clean", 'e', null);
    defer peer.deinit();
    try peer.takeId();
    try std.testing.expectEqual(history.session.Outcome.deleted, try readOutcome(&peer.child));
    try expectExited(try peer.finish(), 0);
    const report = try sweep(&roots.cache);
    try std.testing.expectEqual(@as(u64, 0), report.removed);
    try std.testing.expectEqual(@as(u64, 0), report.protected);
    try std.testing.expectEqual(@as(u64, 0), report.other_hosts);
    try std.testing.expect(!try presentId(&roots.cache, &peer.id));
}

test "host lifecycle subprocess a hangup cleans the session" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var peer = try Peer.spawn(roots.cache_path, "hangup", 'f', null);
    defer peer.deinit();
    try peer.takeId();
    try peer.kill(signals.hangup);
    try std.testing.expectEqual(history.session.Outcome.deleted, try readOutcome(&peer.child));
    try expectExited(try peer.finish(), 0);
    const report = try sweep(&roots.cache);
    try std.testing.expectEqual(@as(u64, 0), report.removed);
    try std.testing.expect(!try presentId(&roots.cache, &peer.id));
}

test "host lifecycle subprocess keep moves to the kept root" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var roots = try Roots.init();
    defer roots.deinit();
    var peer = try Peer.spawn(roots.cache_path, "keep", '7', roots.kept_path);
    defer peer.deinit();
    try peer.takeId();
    try std.testing.expectEqual(history.session.Outcome.moved, try readOutcome(&peer.child));
    try expectExited(try peer.finish(), 0);
    try std.testing.expect(try presentId(&roots.kept, &peer.id));
    try std.testing.expect(!try presentId(&roots.cache, &peer.id));
}
