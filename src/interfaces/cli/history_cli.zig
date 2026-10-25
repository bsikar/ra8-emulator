//! `ra8_emulator history`: the persistent history's command line
//! (RA8EMU-1196, slice 16 M2). The tools open an existing history root of
//! any role and read it; only `rm` and `prune` change it, and both act on
//! single sessions under their own locks, so nothing a live session holds
//! is ever touched. Findings and byte counts go to stdout; complaints go
//! to stderr.
const std = @import("std");
const history = @import("ra8_host").history;
const bind = @import("ra8_rpc").history_bind;
const history_branch_cli = @import("history_branch_cli.zig");

pub const usage =
    \\usage: ra8_emulator history --root DIR ls
    \\       ra8_emulator history --root DIR du [SESSION]
    \\       ra8_emulator history --root DIR rm [--kept] SESSION
    \\       ra8_emulator history --root DIR prune
    \\       ra8_emulator history --root DIR branch ls [SESSION]
    \\       ra8_emulator history --root DIR branch rm [--confirm] SESSION BRANCH_ID
    \\       ls lists the root's entries with their state; du reports bytes,
    \\       all sessions or one; rm removes a session, --kept for a kept
    \\       one; prune sweeps each closed session's orphaned objects and
    \\       leftover frame cache, and never opens a session whose lock
    \\       another host still holds; branch ls lists branches of a session
    \\       or all sessions; branch rm removes a branch with --confirm.
    \\
;

pub const BranchSub = union(enum) {
    ls: ?[]const u8,
    rm: struct { session: []const u8, branch_id: u32, confirm: bool },
};

pub const Op = enum { ls, du, rm, prune, branch };

const Command = struct {
    op: Op,
    root: []const u8,
    entry: ?[]const u8 = null,
    kept: bool = false,
    branch_sub: ?BranchSub = null,
};

/// The flags come in any order; words name the operation and its target.
pub fn parse(argv: []const []const u8) !Command {
    if (argv.len < 3) return error.Usage;
    var root: []const u8 = "";
    var kept = false;
    var confirm = false;
    var words_buf: [8][]const u8 = undefined;
    var words_len: usize = 0;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= argv.len or root.len != 0) return error.Usage;
            root = argv[i];
        } else if (std.mem.eql(u8, arg, "--kept")) {
            if (kept) return error.Usage;
            kept = true;
        } else if (std.mem.eql(u8, arg, "--confirm")) {
            if (confirm) return error.Usage;
            confirm = true;
        } else {
            if (words_len >= words_buf.len) return error.Usage;
            words_buf[words_len] = arg;
            words_len += 1;
        }
    }
    if (root.len == 0 or words_len == 0) return error.Usage;

    const words = words_buf[0..words_len];
    const op = std.meta.stringToEnum(Op, words[0]) orelse return error.Usage;
    var command = Command{ .op = op, .root = root, .kept = kept };

    switch (op) {
        .ls => {
            if (kept or confirm or words.len > 1) return error.Usage;
        },
        .du => {
            if (kept or confirm or words.len > 2) return error.Usage;
            if (words.len == 2) command.entry = words[1];
        },
        .rm => {
            if (confirm or words.len != 2) return error.Usage;
            command.entry = words[1];
        },
        .prune => {
            if (kept or confirm or words.len > 1) return error.Usage;
        },
        .branch => {
            if (kept or words.len < 2) return error.Usage;
            const sub = words[1];
            if (std.mem.eql(u8, sub, "ls")) {
                if (words.len > 3 or confirm) return error.Usage;
                command.branch_sub = .{ .ls = if (words.len == 3) words[2] else null };
            } else if (std.mem.eql(u8, sub, "rm")) {
                if (words.len != 4) return error.Usage;
                const b_id = std.fmt.parseInt(u32, words[3], 0) catch return error.Usage;
                command.branch_sub = .{ .rm = .{ .session = words[2], .branch_id = b_id, .confirm = confirm } };
            } else return error.Usage;
        },
    }
    return command;
}

/// The root the flags name, in the role its own marker claims. The tools
/// try every role rather than one, so a single command line serves cache
/// and kept roots alike; a directory with no marker is refused, never
/// adopted.
fn openRoot(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !history.base.Base {
    const absolute = try absolutePath(allocator, io, path);
    defer allocator.free(absolute);
    inline for (.{ .cache, .kept, .runtime }) |role| {
        if (history.base.Base.existing(allocator, io, absolute, role)) |found| {
            return found;
        } else |err| switch (err) {
            error.WrongRole => {},
            else => return err,
        }
    }
    return error.Unmarked;
}

/// A root path the command line took may be relative; the history root
/// itself must be absolute, so resolve here and once.
fn absolutePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.cwd().realPath(io, &buffer);
    return std.fs.path.join(allocator, &.{ buffer[0..len], path });
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !u8 {
    const command = parse(argv) catch {
        std.Io.File.stderr().writeStreamingAll(io, usage) catch {};
        return 2;
    };
    var base = try openRoot(allocator, io, command.root);
    defer base.close();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const outcome = switch (command.op) {
        .ls => listRoot(&base, &stdout.interface),
        .du => reportBytes(&base, &stdout.interface, command.entry),
        .rm => removeOne(&base, &stdout.interface, command.entry.?, command.kept),
        .prune => sweepClosed(allocator, &base, &stdout.interface),
        .branch => switch (command.branch_sub.?) {
            .ls => |session_name| history_branch_cli.listBranches(allocator, &base, session_name, &stdout.interface),
            .rm => |b_rm| history_branch_cli.removeBranch(allocator, &base, b_rm.session, b_rm.branch_id, b_rm.confirm, &stdout.interface),
        },
    };
    try stdout.interface.flush();
    return outcome catch |err| {
        std.debug.print("history: {s}\n", .{@errorName(err)});
        return 1;
    };
}

/// One line per entry the root holds: name, kind, and the state the
/// catalog read out of it, with kept flags and pointer targets after.
pub fn listRoot(base: *const history.base.Base, out: *std.Io.Writer) !u8 {
    var entries = try history.catalog.Iterator.init(base);
    while (try entries.next()) |entry| {
        try out.print("{s} {s} {s}", .{ entry.name, @tagName(entry.kind), @tagName(entry.status) });
        if (entry.kept) try out.writeAll(" kept");
        if (entry.pointer) |target| try out.print(" -> {s}", .{target});
        try out.writeAll("\n");
    }
    return 0;
}

/// The bytes an entry holds, or every session's bytes plus the total when
/// no session was named.
pub fn reportBytes(base: *const history.base.Base, out: *std.Io.Writer, entry: ?[]const u8) !u8 {
    if (entry) |name| {
        try out.print("{s} {d}\n", .{ name, try history.catalog.du(base, name) });
        return 0;
    }
    var total: u64 = 0;
    var entries = try history.catalog.Iterator.init(base);
    while (try entries.next()) |item| {
        if (item.kind != .session) continue;
        const bytes = try history.catalog.du(base, item.name);
        total += bytes;
        try out.print("{s} {d}\n", .{ item.name, bytes });
    }
    try out.print("total {d}\n", .{total});
    return 0;
}

/// Explicit rm: never a live or foreign session, and a kept one only when
/// `--kept` said so. The lifecycle module enforces both.
pub fn removeOne(base: *const history.base.Base, out: *std.Io.Writer, entry: []const u8, kept: bool) !u8 {
    try history.remove.entryRemove(base, entry, .{ .allow_kept = kept });
    try out.print("removed {s}\n", .{entry});
    return 0;
}

/// The quiescent prune: every closed session the root holds, swept one at
/// a time under its own session lock. A session whose sweep fails is
/// reported and the rest go on; the exit says the run was not clean.
pub fn sweepClosed(allocator: std.mem.Allocator, base: *const history.base.Base, out: *std.Io.Writer) !u8 {
    var failed = false;
    var entries = try history.catalog.Iterator.init(base);
    while (try entries.next()) |entry| {
        const closed = entry.status == .stale or entry.status == .kept;
        if (entry.kind != .session or !closed) continue;
        sweepSession(allocator, base, entry.name, entry.kept, out) catch |err| {
            failed = true;
            try out.print("{s}: {s}\n", .{ entry.name, @errorName(err) });
        };
    }
    return if (failed) 1 else 0;
}

/// One session's sweep: the session lock held, renames settled, the
/// orphan sweep walking the committed log through the RPC bind's
/// referrer, then the frame cache. The session is never closed, so an
/// ephemeral one stays exactly where it is; the lock file and the open
/// directory are all this touch leaves behind.
fn sweepSession(allocator: std.mem.Allocator, base: *const history.base.Base, name: []const u8, kept: bool, out: *std.Io.Writer) !void {
    var dir = try base.dir.openDir(base.io, name, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(base.io);
    var id: history.name.Id = undefined;
    @memcpy(&id, history.name.classify(name).id);
    const held = (try history.lock.take(base.io, base.dir, &id)) orelse return;
    defer held.close(base.io);
    try history.rename.settle(base.io, dir);
    // The storage adapter reads only the session's base, id, dir and
    // lock, so a closed session's sweep goes through the same Store the
    // live recorder uses, with no second adapter to keep honest.
    var session = history.session.Session{ .base = base, .id = id, .dir = dir, .lock = held, .kept = kept };
    const store = history.storage.Store.from(&session);
    const orphans = try history.prune.orphans(store, allocator, bind.prune_referrer);
    const frames = try history.prune.frames(store);
    try out.print("{s}: {d} orphan objects ({d} bytes), {d} frames ({d} bytes)\n", .{ name, orphans.orphans, orphans.orphan_bytes, frames.frames, frames.frame_bytes });
}
