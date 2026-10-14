//! The lifecycle peer: a tiny executable the lifecycle tests spawn as a
//! real second process. It holds a session's lease the way a real front
//! end does, so the tests can prove what the kernel does with the lock
//! across stop, kill and exit, which no in-process simulation can.
//!
//! Argv: `<cache-root> <scenario> <id-char> [kept-root]`. The peer prints
//! its session id, then the outcome of its close, one line each. `hold`
//! blocks until it is killed or stdin closes; `clean` closes and exits;
//! `hangup` closes when the stop plumbing observes a stop request; `keep`
//! marks the session kept and closes into the optional kept root.
const std = @import("std");
const builtin = @import("builtin");
const host = @import("ra8_host");
const history = host.history;

pub fn peer(init: std.process.Init) !u8 {
    switch (builtin.os.tag) {
        .linux => return linuxPeer(init),
        else => return error.NotLinux,
    }
}

fn linuxPeer(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);
    if (argv.len < 4 or argv.len > 5) return error.BadArguments;
    const scenario = argv[2];
    const id: history.name.Id = @splat(argv[3][0]);
    try host.stops.install();
    const base = try history.base.Base.openConfigured(arena, init.io, argv[1], .cache, .{});
    var session = try history.session.Session.create(&base, .{ .id = id });
    try report(init.io, &session.id);
    if (std.mem.eql(u8, scenario, "hold")) {
        var buffer: [1]u8 = undefined;
        while (true) {
            const read = std.posix.read(0, &buffer) catch break;
            if (read == 0) break;
        }
        return closed(init.io, &session, null, .move);
    }
    if (std.mem.eql(u8, scenario, "clean")) return closed(init.io, &session, null, .move);
    if (std.mem.eql(u8, scenario, "hangup")) {
        while (!host.stops.requested()) init.io.sleep(.fromMilliseconds(10), .awake) catch {};
        return closed(init.io, &session, null, .move);
    }
    if (std.mem.eql(u8, scenario, "keep")) {
        if (argv.len != 5) return error.BadArguments;
        var kept = try history.base.Base.openConfigured(arena, init.io, argv[4], .kept, .{});
        try session.keep();
        return closed(init.io, &session, &kept, .move);
    }
    return error.BadScenario;
}

fn closed(io: std.Io, session: *history.session.Session, kept: ?*const history.base.Base, placement: history.session.Placement) !u8 {
    const outcome = try session.close(kept, placement);
    try reportOutcome(io, outcome);
    return 0;
}

fn report(io: std.Io, id: *const history.name.Id) !void {
    var line: [history.name.id_len + 1]u8 = undefined;
    @memcpy(line[0..history.name.id_len], id);
    line[history.name.id_len] = '\n';
    try writeAll(io, &line);
}

fn reportOutcome(io: std.Io, outcome: history.session.Outcome) !void {
    var line: [16]u8 = undefined;
    const tag = @tagName(outcome);
    @memcpy(line[0..tag.len], tag);
    line[tag.len] = '\n';
    try writeAll(io, line[0 .. tag.len + 1]);
}

fn writeAll(io: std.Io, line: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, line);
}
