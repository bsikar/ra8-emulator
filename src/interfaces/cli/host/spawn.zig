//! Starting `serve --stdio` for a host profile (RA8EMU-196). A local
//! profile runs this emulator. An ssh profile runs the remote's, after
//! copying the image into the remote cache under its SHA-256, which is
//! skipped when the remote already holds that file.
const std = @import("std");
const profiles = @import("ra8_host").profiles;

/// Largest image ctl copies to a remote.
const max_image = CacheLimits.image_bytes;

/// Completed, managed images. Incoming images are at most 64 MiB each.
pub const CacheLimits = struct {
    pub const entries = 32;
    pub const image_bytes = 64 * 1024 * 1024;
    pub const bytes = entries * image_bytes;
    pub const lock_attempts = 60;
};

/// The argv that starts `serve --stdio` for the image at `image_path` on
/// `profile`. Memory comes from `allocator`, which ctl runs as an arena.
pub fn serveArgv(allocator: std.mem.Allocator, io: std.Io, profile: profiles.Profile, image_path: []const u8) ![]const []const u8 {
    switch (profile) {
        .local => {
            const exe = try std.process.executablePathAlloc(io, allocator);
            return allocator.dupe([]const u8, &.{ exe, "serve", "--stdio", image_path });
        },
        .ssh => |ssh| {
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, image_path, allocator, .limited(max_image + 1)) catch return error.ImageUnreadable;
            const remote = try cachePath(allocator, ssh.cache, bytes);
            try ensureCopied(allocator, io, ssh, remote, bytes);
            const line = try std.fmt.allocPrint(allocator, "{s} serve --stdio {s}", .{ try quote(allocator, ssh.emulator), try quote(allocator, remote) });
            return allocator.dupe([]const u8, &.{ ssh.program, "-T", ssh.destination, line });
        },
    }
}

/// `cache/<sha256 of bytes>.elf`.
pub fn cachePath(allocator: std.mem.Allocator, cache: []const u8, bytes: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.allocPrint(allocator, "{s}/{x}.elf", .{ cache, &digest });
}

/// Copy bytes, rechecking a probed cache hit inside the locked transaction.
/// ssh exits 255 for its own failures, which is reported as unreachable.
pub fn ensureCopied(allocator: std.mem.Allocator, io: std.Io, ssh: profiles.Ssh, remote: []const u8, bytes: []const u8) !void {
    if (bytes.len > max_image) return error.ImageTooLarge;
    const file = try quote(allocator, remote);
    const probe = try std.fmt.allocPrint(allocator, "test -f {s} && test ! -L {s}", .{ file, file });
    const held = try std.process.run(allocator, io, .{ .argv = &.{ ssh.program, "-T", ssh.destination, probe } });
    defer allocator.free(held.stdout);
    defer allocator.free(held.stderr);
    switch (held.term) {
        .exited => |code| switch (code) {
            0 => {
                const touch = try cacheCommand(allocator, io, ssh.cache, remote, "hit", bytes.len);
                const touched = try std.process.run(allocator, io, .{ .argv = &.{ ssh.program, "-T", ssh.destination, touch } });
                defer allocator.free(touched.stdout);
                defer allocator.free(touched.stderr);
                switch (touched.term) {
                    .exited => |status| switch (status) {
                        0 => return,
                        // Only the locked missing-hit status permits recopy.
                        3 => {},
                        else => return error.CopyFailed,
                    },
                    else => return error.CopyFailed,
                }
            },
            1 => {},
            else => return error.HostUnreachable,
        },
        else => return error.HostUnreachable,
    }
    const store = try cacheCommand(allocator, io, ssh.cache, remote, "store", bytes.len);
    var child = try std.process.spawn(io, .{ .argv = &.{ ssh.program, "-T", ssh.destination, store }, .stdin = .pipe });
    errdefer child.kill(io);
    const written = child.stdin.?.writeStreamingAll(io, bytes);
    child.stdin.?.close(io);
    child.stdin = null;
    if (!exitedClean(try child.wait(io))) return error.CopyFailed;
    try written;
}

fn cacheCommand(allocator: std.mem.Allocator, io: std.Io, cache: []const u8, remote: []const u8, mode: []const u8, size: usize) ![]const u8 {
    var tag: [16]u8 = undefined;
    io.random(&tag);
    const name = std.fs.path.basename(remote);
    const temporary = try std.fmt.allocPrint(allocator, "{s}.part.{x}", .{ name, &tag });
    const script = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ if (std.mem.eql(u8, mode, "store")) "mkdir -p -- \"$1\" || exit 1" else "", cache_script });
    return std.fmt.allocPrint(allocator, "sh -c {s} ra8-image-cache {s} {s} {s} {s} {d} {d} {d} {d}", .{
        try quote(allocator, script),    try quote(allocator, cache), try quote(allocator, name),
        try quote(allocator, temporary), try quote(allocator, mode),  CacheLimits.entries,
        CacheLimits.lock_attempts,       size,                        CacheLimits.image_bytes,
    });
}

// Only hash-named regular files belong to this cache. Shell variables stay
// positional and quoted, so a configured directory cannot become shell code.
const cache_script =
    \\set -eu
    \\dir=$1; file=$2; tmp=$3; mode=$4; limit=$5; attempts=$6; size=$7; max_bytes=$8
    \\case "$dir" in /*) ;; *) dir="./$dir" ;; esac
    \\cd "$dir" || exit 1
    \\hex() { [ "${#1}" -eq "$2" ] || return 1; case "$1" in *[!0-9a-f]*) return 1 ;; esac; }
    \\hex "${file%.elf}" 64 || exit 1
    \\tries=0
    \\until mkdir .ra8-image-lock 2>/dev/null; do
    \\    tries=$((tries + 1)); [ "$tries" -lt "$attempts" ] || exit 1
    \\    sleep 1
    \\done
    \\created=0
    \\cleanup() { status=$?; trap - 0; if [ "$created" -eq 1 ]; then rm -f -- "$tmp" || status=1; fi; rmdir .ra8-image-lock || status=1; exit "$status"; }
    \\trap cleanup 0
    \\trap 'exit 129' HUP
    \\trap 'exit 130' INT
    \\trap 'exit 143' TERM
    \\for part in *.elf.part.*; do
    \\    [ -f "$part" ] && [ ! -L "$part" ] || continue
    \\    hex "${part%%.elf.part.*}" 64 && hex "${part#*.elf.part.}" 32 || continue
    \\    find "$part" -mmin +60 -exec rm -f -- {} + || exit 1
    \\done
    \\set --
    \\for entry in *.elf; do
    \\    [ -f "$entry" ] && [ ! -L "$entry" ] || continue
    \\    hex "${entry%.elf}" 64 || continue
    \\    if [ "$(wc -c < "$entry")" -gt "$max_bytes" ]; then rm -f -- "$entry" || exit 1; continue; fi
    \\    [ "$entry" = "$file" ] || set -- "$@" "$entry"
    \\done
    \\keep=$((limit - 1))
    \\if [ "$#" -gt "$keep" ]; then
    \\    names=$(ls -t -- "$@") || exit 1
    \\    n=0
    \\    for entry in $names; do
    \\        n=$((n + 1))
    \\        if [ "$n" -gt "$keep" ]; then rm -f -- "$entry" || exit 1; fi
    \\    done
    \\fi
    \\if [ -e "$file" ] || [ -L "$file" ]; then
    \\    [ -f "$file" ] && [ ! -L "$file" ] || exit 1
    \\    if [ "$mode" = store ]; then cat > /dev/null || exit 1; fi
    \\    touch -- "$file" || exit 1
    \\else
    \\    if [ "$mode" = hit ]; then exit 3; fi
    \\    [ "$mode" = store ] || exit 1
    \\    set -C; : > "$tmp"; set +C; created=1
    \\    cat > "$tmp" || exit 1
    \\    [ "$(wc -c < "$tmp")" -eq "$size" ] || exit 1
    \\    mv -- "$tmp" "$file" || exit 1
    \\    created=0
    \\fi
;

fn exitedClean(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// `text` single-quoted for the remote shell.
pub fn quote(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (text) |c| {
        if (c == '\'') try out.appendSlice(allocator, "'\\''") else try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}
