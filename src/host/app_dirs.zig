//! Where the emulator keeps its own directories on this host: the ephemeral
//! history under the user's cache directory, kept history under the data
//! directory, and the runtime directory for sockets. Paths only: nothing
//! here opens or makes a directory, so a test can ask for any platform's
//! answer from any host.
const std = @import("std");
const builtin = @import("builtin");

const Env = std.process.Environ.Map;

pub const Platform = enum { xdg, macos, windows };

pub const native: Platform = switch (builtin.os.tag) {
    .windows => .windows,
    .macos => .macos,
    else => .xdg,
};

pub const names = struct {
    pub const app = "ra8_emulator";
    /// Under the cache directory.
    pub const history = "history";
    /// Under the data directory, which on Windows is the cache directory's
    /// parent too, so the two leaves differ.
    pub const kept = "kept_history";
    pub const runtime = "runtime";
    /// Under `$RA8_HISTORY_DIR` and `$RA8_HISTORY_KEPT_DIR`, so an override
    /// that names a directory the user already uses never becomes a root.
    pub const override = "ra8_history";
    pub const kept_override = "ra8_history_kept";
};

pub const variables = struct {
    pub const history = "RA8_HISTORY_DIR";
    pub const kept = "RA8_HISTORY_KEPT_DIR";
};

pub const Error = error{ NoHome, RelativePath } || std.mem.Allocator.Error;

/// The ephemeral history root: `$RA8_HISTORY_DIR/ra8_history`, else the
/// cache directory's `ra8_emulator/history`. The one root that carries a
/// CACHEDIR.TAG.
pub fn historyCache(allocator: std.mem.Allocator, env: *const Env, platform: Platform) Error![]u8 {
    if (try given(env, variables.history, platform)) |base| return join(allocator, platform, &.{ base, names.override });
    const base = try cache(allocator, env, platform);
    defer allocator.free(base);
    return join(allocator, platform, &.{ base, names.app, names.history });
}

/// The kept history root: `$RA8_HISTORY_KEPT_DIR/ra8_history_kept`, else the
/// data directory's `ra8_emulator/kept_history`. Never roaming on Windows.
pub fn historyKept(allocator: std.mem.Allocator, env: *const Env, platform: Platform) Error![]u8 {
    if (try given(env, variables.kept, platform)) |base| return join(allocator, platform, &.{ base, names.kept_override });
    const base = try data(allocator, env, platform);
    defer allocator.free(base);
    return join(allocator, platform, &.{ base, names.app, names.kept });
}

/// The runtime directory for sockets: `$XDG_RUNTIME_DIR/ra8_emulator` where
/// the host has one, else `ra8_emulator/runtime` under the cache directory.
pub fn runtime(allocator: std.mem.Allocator, env: *const Env, platform: Platform) Error![]u8 {
    if (platform == .xdg) {
        if (absolute(env, "XDG_RUNTIME_DIR", platform)) |base| return join(allocator, platform, &.{ base, names.app });
    }
    const base = try cache(allocator, env, platform);
    defer allocator.free(base);
    return join(allocator, platform, &.{ base, names.app, names.runtime });
}

fn cache(allocator: std.mem.Allocator, env: *const Env, platform: Platform) Error![]u8 {
    switch (platform) {
        .xdg => {
            if (absolute(env, "XDG_CACHE_HOME", platform)) |base| return allocator.dupe(u8, base);
            return join(allocator, platform, &.{ try home(env, platform), ".cache" });
        },
        .macos => return join(allocator, platform, &.{ try home(env, platform), "Library", "Caches" }),
        .windows => return local(allocator, env),
    }
}

fn data(allocator: std.mem.Allocator, env: *const Env, platform: Platform) Error![]u8 {
    switch (platform) {
        .xdg => {
            if (absolute(env, "XDG_DATA_HOME", platform)) |base| return allocator.dupe(u8, base);
            return join(allocator, platform, &.{ try home(env, platform), ".local", "share" });
        },
        .macos => return join(allocator, platform, &.{ try home(env, platform), "Library", "Application Support" }),
        .windows => return local(allocator, env),
    }
}

/// %LOCALAPPDATA%, which Windows never roams.
fn local(allocator: std.mem.Allocator, env: *const Env) Error![]u8 {
    if (absolute(env, "LOCALAPPDATA", .windows)) |base| return allocator.dupe(u8, base);
    const profile = absolute(env, "USERPROFILE", .windows) orelse return error.NoHome;
    return join(allocator, .windows, &.{ profile, "AppData", "Local" });
}

fn home(env: *const Env, platform: Platform) Error![]const u8 {
    return absolute(env, "HOME", platform) orelse error.NoHome;
}

/// An override the user set, which must be absolute rather than quietly
/// resolved against wherever the emulator was started.
fn given(env: *const Env, key: []const u8, platform: Platform) Error!?[]const u8 {
    const value = env.get(key) orelse return null;
    if (value.len == 0) return null;
    if (!isAbsolute(value, platform)) return error.RelativePath;
    return trimmed(value, platform);
}

/// A platform variable, ignored unless absolute (as the XDG rules say).
fn absolute(env: *const Env, key: []const u8, platform: Platform) ?[]const u8 {
    const value = env.get(key) orelse return null;
    if (!isAbsolute(value, platform)) return null;
    return trimmed(value, platform);
}

fn isAbsolute(path: []const u8, platform: Platform) bool {
    return switch (platform) {
        .windows => std.fs.path.isAbsoluteWindows(path),
        .xdg, .macos => std.fs.path.isAbsolutePosix(path),
    };
}

fn trimmed(path: []const u8, platform: Platform) []const u8 {
    const seps: []const u8 = if (platform == .windows) "\\/" else "/";
    const cut = std.mem.trimEnd(u8, path, seps);
    const root_len: usize = if (platform == .windows) 3 else 1;
    return if (cut.len < root_len) path[0..@min(path.len, root_len)] else cut;
}

fn join(allocator: std.mem.Allocator, platform: Platform, parts: []const []const u8) Error![]u8 {
    const sep: []const u8 = if (platform == .windows) "\\" else "/";
    const root = std.mem.endsWith(u8, parts[0], sep);
    const head = if (root) parts[0][0 .. parts[0].len - 1] else parts[0];
    const rest = try std.mem.join(allocator, sep, parts[1..]);
    defer allocator.free(rest);
    return std.mem.concat(allocator, u8, &.{ head, sep, rest });
}
