//! `ctl --host NAME --image ELF` over a local profile and over an ssh
//! profile (RA8EMU-196). The ssh profile runs a stand-in for ssh that drops
//! the destination and runs the remote command here, so the copy-by-hash
//! and the remote `serve --stdio` are exercised without a network.
const std = @import("std");
const test_paths = @import("test_paths");
const uart_image = @import("ctl_run.zig").uart_image;

const fake_ssh =
    \\#!/bin/sh
    \\echo "$@" >> "$(dirname "$0")/ssh.log"
    \\shift 2
    \\exec sh -c "$*"
    \\
;

const Rig = struct {
    tmp: std.testing.TmpDir,
    root: [:0]const u8,
    hosts: []const u8,

    fn init(gpa: std.mem.Allocator) !Rig {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
        errdefer gpa.free(root);
        const script = try tmp.dir.createFile(std.testing.io, "fake_ssh", .{ .permissions = .executable_file });
        try script.writeStreamingAll(std.testing.io, fake_ssh);
        script.close(std.testing.io);
        const native = @import("builtin").os.tag == .windows;
        const program = if (native) test_paths.ssh_fixture else try std.fs.path.join(gpa, &.{ root, "fake_ssh" });
        defer if (!native) gpa.free(program);
        const destination = if (native) root else "labvm";
        const lines = try std.fmt.allocPrint(gpa, "local here\nssh lab {s} emulator={s} cache={s}/cache ssh={s}\n", .{ destination, test_paths.emulator, root, program });
        defer gpa.free(lines);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "hosts", .data = lines });
        return .{ .tmp = tmp, .root = root, .hosts = try std.fs.path.join(gpa, &.{ root, "hosts" }) };
    }

    fn deinit(self: *Rig, gpa: std.mem.Allocator) void {
        gpa.free(self.hosts);
        gpa.free(self.root);
        self.tmp.cleanup();
    }

    /// Run one ctl command on `host` and return its stdout; exit 0 is required.
    fn ctl(self: *const Rig, gpa: std.mem.Allocator, host: []const u8, words: []const []const u8) ![]u8 {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ test_paths.emulator, "ctl", "--host", host, "--hosts", self.hosts, "--image", uart_image, "--json" });
        try argv.appendSlice(gpa, words);
        const result = try std.process.run(gpa, std.testing.io, .{ .argv = argv.items });
        defer gpa.free(result.stderr);
        errdefer gpa.free(result.stdout);
        if (!std.meta.eql(std.process.Child.Term{ .exited = 0 }, result.term)) {
            std.debug.print("ctl fixture failed: stdout={s} stderr={s}\n", .{ result.stdout[0..@min(result.stdout.len, 1024)], result.stderr[0..@min(result.stderr.len, 1024)] });
        }
        try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
        return result.stdout;
    }

    fn count(self: *const Rig, gpa: std.mem.Allocator, needle: []const u8) !usize {
        const log = try self.tmp.dir.readFileAlloc(std.testing.io, "ssh.log", gpa, .limited(64 * 1024));
        defer gpa.free(log);
        return std.mem.count(u8, log, needle);
    }
};

test "a run over an ssh profile matches the same run over a local profile" {
    const gpa = std.testing.allocator;
    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);
    const local = try rig.ctl(gpa, "here", &.{ "run", "--budget", "20000" });
    defer gpa.free(local);
    const remote = try rig.ctl(gpa, "lab", &.{ "run", "--budget", "20000" });
    defer gpa.free(remote);
    try std.testing.expect(std.mem.indexOf(u8, local, "\"stopped\"") != null);
    try std.testing.expectEqualStrings(local, remote);
}

test "the image is copied to the remote cache once and reused after that" {
    const gpa = std.testing.allocator;
    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);
    for (0..2) |_| gpa.free(try rig.ctl(gpa, "lab", &.{ "regs", "pc" }));
    try std.testing.expectEqual(@as(usize, 2), try rig.count(gpa, "test -f"));
    try std.testing.expectEqual(@as(usize, 1), try rig.count(gpa, "mkdir -p"));
    try std.testing.expectEqual(@as(usize, 2), try rig.count(gpa, "serve --stdio"));
    var cache = try rig.tmp.dir.openDir(std.testing.io, "cache", .{ .iterate = true });
    defer cache.close(std.testing.io);
    var it = cache.iterate();
    const entry = (try it.next(std.testing.io)).?;
    try std.testing.expect(std.mem.endsWith(u8, entry.name, ".elf"));
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(std.testing.io));
}

test "an unknown profile names the hosts file problem and exits 1" {
    const gpa = std.testing.allocator;
    var rig = try Rig.init(gpa);
    defer rig.deinit(gpa);
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = &.{ test_paths.emulator, "ctl", "--host", "nowhere", "--hosts", rig.hosts, "--image", uart_image, "--json", "pause" } });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"error\":\"UnknownHost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "\"message\":") != null);
}

// Native executable stand-in for the SSH fixture. Compiled from this owner
// file on Windows; the POSIX tests retain their real shell script above.
pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 4 or !std.mem.eql(u8, args[1], "-T")) return 255;
    const log_path = try std.fs.path.join(gpa, &.{ args[2], "ssh.log" });
    const log = try std.Io.Dir.cwd().createFile(init.io, log_path, .{ .truncate = false, .read = true });
    defer log.close(init.io);
    const line = try std.fmt.allocPrint(gpa, "{s}\n", .{args[3]});
    try log.writePositionalAll(init.io, line, (try log.stat(init.io)).size);
    const words = try remoteWords(gpa, args[3]);
    if (words.len == 8 and std.mem.eql(u8, words[0], "test") and std.mem.eql(u8, words[1], "-f")) {
        const stat = std.Io.Dir.cwd().statFile(init.io, words[2], .{ .follow_symlinks = false }) catch |err| return switch (err) {
            error.FileNotFound => 1,
            else => err,
        };
        if (stat.kind != .file) return 1;
        try pauseProbe(init.io, args[2]);
        return 0;
    }
    if (words.len == 12 and std.mem.eql(u8, words[0], "sh") and std.mem.eql(u8, words[1], "-c") and std.mem.eql(u8, words[3], "ra8-image-cache")) {
        if (std.mem.eql(u8, words[7], "hit")) {
            const failure = try std.fs.path.join(gpa, &.{ args[2], "hit.fail" });
            if (std.Io.Dir.cwd().access(init.io, failure, .{})) |_| return 7 else |err| if (err != error.FileNotFound) return err;
        }
        return cacheImage(gpa, init.io, words);
    }
    if (words.len != 4 or !std.mem.eql(u8, words[1], "serve") or !std.mem.eql(u8, words[2], "--stdio")) return 255;
    var child = try std.process.spawn(init.io, .{ .argv = words, .stdin = .inherit, .stdout = .inherit, .stderr = .inherit });
    return switch (try child.wait(init.io)) {
        .exited => |code| code,
        else => 255,
    };
}

fn cacheImage(gpa: std.mem.Allocator, io: std.Io, words: []const []const u8) !u8 {
    if (!managedImage(words[5]) or !std.mem.startsWith(u8, words[6], words[5])) return 255;
    const limit = try std.fmt.parseInt(usize, words[8], 10);
    const size = try std.fmt.parseInt(usize, words[10], 10);
    if (limit != 32 or size > 64 * 1024 * 1024 or try std.fmt.parseInt(usize, words[11], 10) != 64 * 1024 * 1024) return 255;
    try std.Io.Dir.cwd().createDirPath(io, words[4]);
    var cache = try std.Io.Dir.cwd().openDir(io, words[4], .{ .iterate = true });
    defer cache.close(io);
    if (!try cacheLock(io, cache, try std.fmt.parseInt(usize, words[9], 10))) return 1;
    defer cache.deleteDir(io, ".ra8-image-lock") catch |err| std.debug.print("fixture lock cleanup: {s}\n", .{@errorName(err)});
    try staleParts(io, cache);
    try prune(gpa, io, cache, words[5], limit);
    const stat = cache.statFile(io, words[5], .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (stat) |held| {
        if (held.kind != .file) return 1;
        if (std.mem.eql(u8, words[7], "store")) _ = try incoming(gpa, io);
        const file = try cache.openFile(io, words[5], .{ .mode = .read_write });
        defer file.close(io);
        try file.setTimestampsNow(io);
    } else {
        if (!std.mem.eql(u8, words[7], "store")) return if (std.mem.eql(u8, words[7], "hit")) 3 else 1;
        const part = try cache.createFile(io, words[6], .{ .exclusive = true });
        var open = true;
        defer cache.deleteFile(io, words[6]) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.debug.print("fixture partial cleanup: {s}\n", .{@errorName(err)}),
        };
        defer if (open) part.close(io);
        const bytes = try incoming(gpa, io);
        const copied = part.writeStreamingAll(io, bytes);
        part.close(io);
        open = false;
        try copied;
        if (bytes.len != size) return 1;
        if (cache.access(io, "copy.fail", .{})) |_| return 1 else |err| if (err != error.FileNotFound) return err;
        try cache.rename(words[6], cache, words[5], io);
    }
    return 0;
}

fn cacheLock(io: std.Io, cache: std.Io.Dir, limit: usize) !bool {
    var attempts: usize = 0;
    while (true) {
        cache.createDir(io, ".ra8-image-lock", .default_dir) catch |err| {
            if (err != error.PathAlreadyExists) return err;
            attempts += 1;
            if (attempts >= limit) return false;
            try std.Io.sleep(io, .fromSeconds(1), .awake);
            continue;
        };
        return true;
    }
}

fn incoming(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var buffer: [4096]u8 = undefined;
    var input = std.Io.File.stdin().reader(io, &buffer);
    return input.interface.allocRemaining(gpa, .limited(64 * 1024 * 1024 + 1));
}

fn managedImage(name: []const u8) bool {
    if (name.len != 68 or !std.mem.endsWith(u8, name, ".elf")) return false;
    for (name[0..64]) |c| if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

fn staleParts(io: std.Io, cache: std.Io.Dir) !void {
    var it = cache.iterate();
    const now = std.Io.Timestamp.now(io, .real).toNanoseconds();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or entry.name.len != 106 or !managedImage(entry.name[0..68]) or !std.mem.eql(u8, entry.name[68..74], ".part.")) continue;
        var valid = true;
        for (entry.name[74..]) |c| {
            if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) valid = false;
        }
        if (!valid) continue;
        const stat = try cache.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file) continue;
        if (now - stat.mtime.toNanoseconds() > 61 * std.time.ns_per_min) try cache.deleteFile(io, entry.name);
    }
}

fn prune(gpa: std.mem.Allocator, io: std.Io, cache: std.Io.Dir, current: []const u8, limit: usize) !void {
    const Entry = struct { name: []const u8, modified: i96 };
    var entries: std.ArrayList(Entry) = .empty;
    var it = cache.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !managedImage(entry.name)) continue;
        const stat = try cache.statFile(io, entry.name, .{ .follow_symlinks = false });
        if (stat.kind != .file) continue;
        if (stat.size > 64 * 1024 * 1024) {
            try cache.deleteFile(io, entry.name);
            continue;
        }
        if (std.mem.eql(u8, entry.name, current)) continue;
        try entries.append(gpa, .{ .name = try gpa.dupe(u8, entry.name), .modified = stat.mtime.toNanoseconds() });
    }
    const Order = struct {
        fn before(_: void, a: Entry, b: Entry) bool {
            if (a.modified != b.modified) return a.modified > b.modified;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    };
    std.mem.sort(Entry, entries.items, {}, Order.before);
    if (entries.items.len >= limit) for (entries.items[limit - 1 ..]) |entry| try cache.deleteFile(io, entry.name);
}

/// The fixture accepts the single-quoted argv emitted by host.spawn.quote,
/// including adjacent quoted/unquoted pieces and an escaped quote.
fn remoteWords(gpa: std.mem.Allocator, line: []const u8) ![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;
    while (at < line.len) {
        while (at < line.len and line[at] == ' ') : (at += 1) {}
        if (at == line.len) break;
        var word: std.ArrayList(u8) = .empty;
        var quoted = false;
        while (at < line.len and (quoted or line[at] != ' ')) : (at += 1) {
            if (line[at] == '\'') {
                quoted = !quoted;
            } else if (!quoted and line[at] == '\\') {
                at += 1;
                if (at == line.len) return error.BadCommand;
                try word.append(gpa, line[at]);
            } else try word.append(gpa, line[at]);
        }
        if (quoted) return error.BadCommand;
        try words.append(gpa, try word.toOwnedSlice(gpa));
    }
    return words.toOwnedSlice(gpa);
}

test "the native SSH stand-in decodes the real remote argv quoting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = try remoteWords(arena.allocator(), "mkdir -p 'C:\\temp\\a b' && cat > 'C:\\temp\\a b/img'.part && mv 'C:\\temp\\a b/img'.part 'C:\\temp\\a b/img'");
    try std.testing.expectEqual(@as(usize, 11), words.len);
    try std.testing.expectEqualStrings("C:\\temp\\a b", words[2]);
    try std.testing.expectEqualStrings("C:\\temp\\a b/img.part", words[6]);
    const quoted = try @import("cli_app").host.spawn.quote(arena.allocator(), "a'b");
    const decoded = try remoteWords(arena.allocator(), quoted);
    try std.testing.expectEqualStrings("a'b", decoded[0]);
}

// Barrier after a successful unlocked probe, entirely in owned fixture data.
fn pauseProbe(io: std.Io, root: []const u8) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{});
    defer dir.close(io);
    dir.access(io, "probe.pause", .{}) catch |err| return if (err == error.FileNotFound) {} else err;
    try dir.writeFile(io, .{ .sub_path = "probe.ready", .data = "successful probe paused" });
    for (0..1000) |_| {
        if (dir.access(io, "probe.resume", .{})) |_| return else |err| if (err != error.FileNotFound) return err;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.ProbeResumeTimeout;
}
