//! Remote-image cache transactions on owned paths. Linux uses the real
//! emitted shell command. Windows uses the existing native SSH stand-in.
const std = @import("std");
const ra8 = @import("ra8");
const spawn = @import("cli_app").host.spawn;
const test_paths = @import("test_paths");
const native = @import("builtin").os.tag == .windows;
const io = std.testing.io;

const ssh_script =
    \\#!/bin/sh
    \\root=$(dirname "$0")
    \\PATH="$root/bin:$PATH"; export PATH
    \\shift 2
    \\case "$1" in
    \\    "test -f "*)
    \\        sh -c "$1"; status=$?
    \\        if [ "$status" -eq 0 ] && [ -f "$root/probe.pause" ]; then
    \\            : > "$root/probe.ready"
    \\            n=0
    \\            while [ ! -f "$root/probe.resume" ]; do
    \\                n=$((n + 1)); [ "$n" -lt 1000 ] || exit 1
    \\                sleep .01
    \\            done
    \\        fi
    \\        exit "$status" ;;
    \\    *" 'hit' "*) [ ! -f "$root/hit.fail" ] || exit 7 ;;
    \\esac
    \\exec sh -c "$1"
;

const cat_script =
    \\#!/bin/sh
    \\root=$(dirname "$(dirname "$0")")
    \\if [ -f "$root/cache dir'quote/copy.fail" ]; then
    \\    /bin/cat "$@"
    \\    exit 1
    \\fi
    \\exec /bin/cat "$@"
;

const Rig = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    cache: std.Io.Dir,
    ssh: ra8.host.profiles.Ssh,

    fn init() !Rig {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer arena.deinit();
        const gpa = arena.allocator();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        try tmp.dir.createDirPath(io, "cache dir'quote");
        var cache = try tmp.dir.openDir(io, "cache dir'quote", .{ .iterate = true });
        errdefer cache.close(io);
        try tmp.dir.createDirPath(io, "bin");
        try executable(tmp.dir, "fake_ssh", ssh_script);
        try executable(tmp.dir, "bin/cat", cat_script);
        return .{ .arena = arena, .tmp = tmp, .cache = cache, .ssh = .{
            .destination = if (native) root else "owned-fixture",
            .cache = try std.fs.path.join(gpa, &.{ root, "cache dir'quote" }),
            .program = if (native) test_paths.ssh_fixture else try std.fs.path.join(gpa, &.{ root, "fake_ssh" }),
        } };
    }

    fn deinit(self: *Rig) void {
        self.cache.close(io);
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn copy(self: *Rig, bytes: []const u8) ![]const u8 {
        const gpa = self.arena.allocator();
        const remote = try spawn.cachePath(gpa, self.ssh.cache, bytes);
        try spawn.ensureCopied(gpa, io, self.ssh, remote, bytes);
        return std.fs.path.basename(remote);
    }

    fn payload(self: *Rig, name: []const u8, expected: []const u8) !void {
        const actual = try self.cache.readFileAlloc(io, name, self.arena.allocator(), .limited(1024));
        try std.testing.expectEqualStrings(expected, actual);
    }

    fn clean(self: *Rig, expected: usize) !void {
        var it = self.cache.iterate();
        var count: usize = 0;
        while (try it.next(io)) |entry| {
            try std.testing.expect(std.mem.indexOf(u8, entry.name, ".elf.part.") == null);
            try std.testing.expect(!std.mem.eql(u8, entry.name, ".ra8-image-lock"));
            if (entry.kind == .file and entry.name.len == 68) count += 1;
        }
        try std.testing.expectEqual(expected, count);
    }
};

fn executable(dir: std.Io.Dir, name: []const u8, text: []const u8) !void {
    const file = try dir.createFile(io, name, .{ .permissions = .executable_file });
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

fn imageName(out: *[68]u8, index: usize) ![]const u8 {
    return std.fmt.bufPrint(out, "{x:0>64}.elf", .{index});
}

fn old(dir: std.Io.Dir, name: []const u8, seconds: i64) !void {
    const file = try dir.openFile(io, name, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s) } });
}

test "remote cache bounds completed images, refreshes hits and keeps unrelated paths" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.cache.writeFile(io, .{ .sub_path = "notes.elf", .data = "unrelated" });
    var directory_buffer: [68]u8 = undefined;
    const directory = try imageName(&directory_buffer, 999);
    try rig.cache.createDir(io, directory, .default_dir);
    for (0..spawn.CacheLimits.entries) |index| {
        var name_buffer: [68]u8 = undefined;
        const name = try imageName(&name_buffer, index);
        try rig.cache.writeFile(io, .{ .sub_path = name, .data = "seed" });
        try old(rig.cache, name, @intCast(100 + index));
    }
    const first = try rig.copy("first image bytes");
    try rig.clean(spawn.CacheLimits.entries);
    try old(rig.cache, first, 1);
    try std.testing.expectEqualStrings(first, try rig.copy("first image bytes"));
    const refreshed = try rig.cache.statFile(io, first, .{});
    try std.testing.expect(refreshed.mtime.toNanoseconds() > 1000 * std.time.ns_per_s);
    const second = try rig.copy("second image bytes");
    try rig.clean(spawn.CacheLimits.entries);
    try rig.payload(first, "first image bytes");
    try rig.payload(second, "second image bytes");
    try rig.payload("notes.elf", "unrelated");
    try std.testing.expectEqual(std.Io.File.Kind.directory, (try rig.cache.statFile(io, directory, .{})).kind);
    for (0..2) |index| {
        var name_buffer: [68]u8 = undefined;
        try std.testing.expectError(error.FileNotFound, rig.cache.access(io, try imageName(&name_buffer, index), .{}));
    }
}

test "a failed remote copy removes its unique partial and leaves unrelated data" {
    var rig = try Rig.init();
    defer rig.deinit();
    try rig.cache.writeFile(io, .{ .sub_path = "copy.fail", .data = "owned failure switch" });
    try rig.cache.writeFile(io, .{ .sub_path = "notes.elf", .data = "unrelated" });
    try std.testing.expectError(error.CopyFailed, rig.copy("failed image bytes"));
    try rig.clean(0);
    try rig.payload("notes.elf", "unrelated");
    try rig.payload("copy.fail", "owned failure switch");
    try rig.cache.deleteFile(io, "copy.fail");
    const name = try rig.copy("failed image bytes");
    try rig.payload(name, "failed image bytes");
    try rig.clean(1);
}

test "remote cache recovers old owned partials and preserves fresh and foreign files" {
    var rig = try Rig.init();
    defer rig.deinit();
    var hash_buffer: [68]u8 = undefined;
    const hash = try imageName(&hash_buffer, 100);
    const gpa = rig.arena.allocator();
    const stale = try std.fmt.allocPrint(gpa, "{s}.part.{s}", .{ hash, "00000000000000000000000000000000" });
    const fresh = try std.fmt.allocPrint(gpa, "{s}.part.{s}", .{ hash, "00000000000000000000000000000001" });
    const foreign = "personal.elf.part.00000000000000000000000000000000";
    for ([_][]const u8{ stale, fresh, foreign }) |name| try rig.cache.writeFile(io, .{ .sub_path = name, .data = "preserve unless stale owned" });
    try old(rig.cache, stale, 100);
    try old(rig.cache, foreign, 100);
    _ = try rig.copy("recovery image");
    try std.testing.expectError(error.FileNotFound, rig.cache.access(io, stale, .{}));
    try rig.payload(fresh, "preserve unless stale owned");
    try rig.payload(foreign, "preserve unless stale owned");
    try std.testing.expectError(error.FileNotFound, rig.cache.access(io, ".ra8-image-lock", .{}));
}

test "cache maintenance preserves a hash-named symlink and its target" {
    var rig = try Rig.init();
    defer rig.deinit();
    if (native) {
        try rig.tmp.dir.createDir(io, "untouched-target", .default_dir);
        try rig.tmp.dir.writeFile(io, .{ .sub_path = "untouched-target/sentinel", .data = "unrelated" });
    } else try rig.tmp.dir.writeFile(io, .{ .sub_path = "untouched-target", .data = "unrelated" });
    var buffer: [68]u8 = undefined;
    const name = try imageName(&buffer, 1000);
    try ownedSymlink(&rig, name);
    _ = try rig.copy("cache maintenance");
    const stat = try rig.cache.statFile(io, name, .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, stat.kind);
    if (native) {
        const through_link = try std.fmt.allocPrint(rig.arena.allocator(), "{s}/sentinel", .{name});
        try rig.payload(through_link, "unrelated");
    } else try rig.payload(name, "unrelated");
    const target = try rig.tmp.dir.readFileAlloc(io, if (native) "untouched-target/sentinel" else "untouched-target", rig.arena.allocator(), .limited(100));
    try std.testing.expectEqualStrings("unrelated", target);
}

const Copy = struct {
    ssh: ra8.host.profiles.Ssh,
    bytes: []const u8,
    failure: ?anyerror = null,

    fn run(self: *Copy) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        const remote = spawn.cachePath(gpa, self.ssh.cache, self.bytes) catch |err| {
            self.failure = err;
            return;
        };
        spawn.ensureCopied(gpa, io, self.ssh, remote, self.bytes) catch |err| {
            self.failure = err;
        };
    }
};

test "concurrent copies publish one complete image and leave no partials" {
    var rig = try Rig.init();
    defer rig.deinit();
    const bytes = try rig.arena.allocator().alloc(u8, 1024 * 1024);
    @memset(bytes, 0xa5);
    var first: Copy = .{ .ssh = rig.ssh, .bytes = bytes };
    var second: Copy = .{ .ssh = rig.ssh, .bytes = bytes };
    const one = try std.Thread.spawn(.{}, Copy.run, .{&first});
    const two = std.Thread.spawn(.{}, Copy.run, .{&second}) catch |err| {
        one.join();
        return err;
    };
    one.join();
    two.join();
    if (first.failure) |err| return err;
    if (second.failure) |err| return err;
    try rig.clean(1);
    const remote = try spawn.cachePath(rig.arena.allocator(), rig.ssh.cache, bytes);
    const actual = try rig.cache.readFileAlloc(io, std.fs.path.basename(remote), rig.arena.allocator(), .limited(bytes.len + 1));
    try std.testing.expectEqualSlices(u8, bytes, actual);
}

test "cache shell quoting preserves single quotes and metacharacters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("'a'\\''b;$(x)'", try spawn.quote(arena.allocator(), "a'b;$(x)"));
}

test "remote cache rejects oversized inputs and removes oversized managed entries" {
    var rig = try Rig.init();
    defer rig.deinit();
    var buffer: [68]u8 = undefined;
    const oversized = try imageName(&buffer, 1001);
    const file = try rig.cache.createFile(io, oversized, .{});
    try file.setLength(io, spawn.CacheLimits.image_bytes + 1);
    file.close(io);
    try rig.cache.writeFile(io, .{ .sub_path = "notes.elf", .data = "foreign" });
    _ = try rig.copy("within bound");
    try std.testing.expectError(error.FileNotFound, rig.cache.access(io, oversized, .{}));
    try rig.payload("notes.elf", "foreign");
    const bytes = try rig.arena.allocator().alloc(u8, spawn.CacheLimits.image_bytes + 1);
    @memset(bytes, 0x5a);
    const maximum = try rig.copy(bytes[0..spawn.CacheLimits.image_bytes]);
    try std.testing.expectEqual(@as(u64, spawn.CacheLimits.image_bytes), (try rig.cache.statFile(io, maximum, .{})).size);
    try std.testing.expectError(error.ImageTooLarge, spawn.ensureCopied(rig.arena.allocator(), io, rig.ssh, "unused", bytes));
    try rig.clean(2);
}

// An actual NTFS junction covers native reparse-link exclusion without
// changing host symlink privileges. POSIX retains the real file symlink.
fn ownedSymlink(rig: *Rig, name: []const u8) !void {
    if (!native) return rig.cache.symLink(io, "../untouched-target", name, .{});
    const gpa = rig.arena.allocator();
    const root = try rig.tmp.dir.realPathFileAlloc(io, ".", gpa);
    const link = try std.fs.path.join(gpa, &.{ rig.ssh.cache, name });
    const target = try std.fs.path.join(gpa, &.{ root, "untouched-target" });
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, target } });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
}

test "a successful probe evicted before its locked hit recopies exact bytes" {
    var rig = try Rig.init();
    defer rig.deinit();
    const bytes = "oldest image A";
    const first = try rig.copy(bytes);
    try old(rig.cache, first, 1);
    for (1..spawn.CacheLimits.entries) |index| {
        var buffer: [68]u8 = undefined;
        const name = try imageName(&buffer, index);
        try rig.cache.writeFile(io, .{ .sub_path = name, .data = "seed" });
        try old(rig.cache, name, @intCast(100 + index));
    }
    try rig.clean(spawn.CacheLimits.entries);
    try rig.tmp.dir.writeFile(io, .{ .sub_path = "probe.pause", .data = "owned barrier" });
    var pending: Copy = .{ .ssh = rig.ssh, .bytes = bytes };
    const thread = try std.Thread.spawn(.{}, Copy.run, .{&pending});
    var joined = false;
    defer if (!joined) {
        rig.tmp.dir.writeFile(io, .{ .sub_path = "probe.resume", .data = "cleanup release" }) catch |err| std.debug.print("fixture resume: {s}\n", .{@errorName(err)});
        thread.join();
    };
    try waitForProbe(rig.tmp.dir);
    _ = try rig.copy("new image B evicts oldest A");
    try std.testing.expectError(error.FileNotFound, rig.cache.access(io, first, .{}));
    try rig.tmp.dir.writeFile(io, .{ .sub_path = "probe.resume", .data = "B evicted A" });
    thread.join();
    joined = true;
    if (pending.failure) |err| return err;
    try rig.payload(first, bytes);
    try rig.clean(spawn.CacheLimits.entries);
}

fn waitForProbe(dir: std.Io.Dir) !void {
    for (0..1000) |_| {
        if (dir.access(io, "probe.ready", .{})) |_| return else |err| if (err != error.FileNotFound) return err;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.ProbePauseTimeout;
}

test "an arbitrary locked hit failure does not become a cache miss" {
    var rig = try Rig.init();
    defer rig.deinit();
    const bytes = "present image with failing hit transport";
    const name = try rig.copy(bytes);
    try rig.tmp.dir.writeFile(io, .{ .sub_path = "hit.fail", .data = "owned nonmissing failure" });
    try std.testing.expectError(error.CopyFailed, rig.copy(bytes));
    try rig.payload(name, bytes);
    try rig.clean(1);
}
