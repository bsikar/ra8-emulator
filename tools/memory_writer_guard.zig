//! Standalone memory-writer boundary scanner (RA8EMU-1234 / AM09).
//!
//! Verifies that mutable and raw backing-store reaches inside `src/` stay
//! confined to the H1-H6 hooked writers, barriers, raw/incremental restore,
//! external-backing owners, and snapshot serialization modules, and that
//! `src/chip/core/cpu/memory/` contains no `@constCast` bypasses.
const std = @import("std");

/// Modules allowed to use writer, raw-restore, and backing-slice primitives.
pub const writer_allowlist = [_][]const u8{
    "src/chip/core/cpu/memory/store.zig",
    "src/chip/core/cpu/memory/extra.zig",
    "src/chip/core/cpu/memory/bus.zig",
    "src/chip/core/cpu/bus.zig",
    "src/chip/core/cpu/memory/mapped.zig",
    "src/chip/core/cpu/memory/external_port.zig",
    "src/board/external/backing.zig",
    "src/board/external/memory.zig",
    "src/board/snapshot/memory.zig",
    "src/components/nor_flash/flash.zig",
    "src/components/nor_flash/lines.zig",
    "src/session/history/trail.zig",
    "src/session/history/window_record.zig",
    "src/session/history/window_trail.zig",
    "src/session/history/incremental_restore.zig",
};

/// Modules allowed read-only inspection of `store.pages` (never mutable hooks).
pub const readonly_backing_allowlist = [_][]const u8{
    "src/session/history/shadow_oracle.zig",
};

pub const writer_tokens = [_][]const u8{
    ".locateMut(",
    ".mutRegion(",
    ".touchesMut(",
    ".rawWrite(",
    "rawWriteFn",
};

pub const backing_tokens = [_][]const u8{
    "extra.windows",
    "store.pages",
    "first.pages",
    "memory.pages",
    "s.pages[",
    "?.sdram",
};

/// Canonicalize `path` to forward-slash `src/...` form when under `src/`.
pub fn canonicalSrcPath(path: []const u8, buf: *[512]u8) ?[]const u8 {
    if (path.len > buf.len) return null;
    for (path, 0..) |ch, i| buf[i] = if (ch == '\\') '/' else ch;
    const norm = buf[0..path.len];
    if (std.mem.startsWith(u8, norm, "src/")) return norm;
    var at: usize = 0;
    var best: ?usize = null;
    while (std.mem.indexOfPos(u8, norm, at, "/src/")) |hit| : (at = hit + 1) {
        best = hit + 1;
    }
    return if (best) |idx| norm[idx..] else null;
}

pub fn isWriterAllowed(rel_path: []const u8) bool {
    for (writer_allowlist) |allowed| {
        if (std.mem.eql(u8, rel_path, allowed)) return true;
    }
    return false;
}

pub fn isReadonlyBackingAllowed(rel_path: []const u8) bool {
    for (readonly_backing_allowlist) |allowed| {
        if (std.mem.eql(u8, rel_path, allowed)) return true;
    }
    return false;
}

/// Strip comments and string literal payloads from one source line.
fn stripCode(line: []const u8, out: *[2048]u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    var in_str = false;
    while (i < line.len and n < out.len) : (i += 1) {
        if (!in_str and i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') break;
        if (line[i] == '"') {
            in_str = !in_str;
            out[n] = '"';
            n += 1;
            continue;
        }
        if (in_str) {
            if (line[i] == '\\' and i + 1 < line.len) i += 1;
            continue;
        }
        out[n] = line[i];
        n += 1;
    }
    return out[0..n];
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

fn hasRawPortSdram(code: []const u8) bool {
    const needle = "port.sdram";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, code, from, needle)) |at| : (from = at + needle.len) {
        if (at > 0 and isIdentChar(code[at - 1])) continue;
        const rest = code[at + needle.len ..];
        if (rest.len > 0 and isIdentChar(rest[0])) continue;
        if (!std.mem.startsWith(u8, rest, ".len")) return true;
    }
    return false;
}

/// First unapproved mutable/backing token on `line` for `rel_path`, or null.
pub fn firstViolation(rel_path: []const u8, line: []const u8) ?[]const u8 {
    var code_buf: [2048]u8 = undefined;
    const code = stripCode(line, &code_buf);
    if (code.len == 0) return null;

    if (std.mem.startsWith(u8, rel_path, "src/chip/core/cpu/memory/")) {
        if (std.mem.indexOf(u8, code, "@constCast(") != null) return "@constCast(";
    }

    if (isWriterAllowed(rel_path)) return null;

    for (writer_tokens) |tok| {
        if (std.mem.indexOf(u8, code, tok) != null) return tok;
    }

    if (isReadonlyBackingAllowed(rel_path)) return null;

    for (backing_tokens) |tok| {
        if (std.mem.indexOf(u8, code, tok) != null) return tok;
    }
    if (hasRawPortSdram(code)) return "port.sdram";
    return null;
}

pub fn checkText(rel_path: []const u8, text: []const u8, out: *std.Io.Writer) !usize {
    var findings: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const tok = firstViolation(rel_path, line) orelse continue;
        findings += 1;
        try out.print("{s}:{d}: unapproved backing access \"{s}\"\n", .{ rel_path, line_no, tok });
    }
    return findings;
}

fn isIgnored(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part[0] == '.' or std.mem.eql(u8, part, "zig-out") or std.mem.eql(u8, part, "zig-pkg")) return true;
    }
    return false;
}

pub const Summary = struct {
    scanned: usize = 0,
    findings: usize = 0,
};

pub fn scanPath(alloc: std.mem.Allocator, io: std.Io, root: []const u8, out: *std.Io.Writer) !Summary {
    var summary: Summary = .{};
    var dir = std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            try checkFile(alloc, io, root, out, &summary);
            return summary;
        },
        else => return err,
    };
    defer dir.close(io);
    var it = try dir.walk(alloc);
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (isIgnored(entry.path)) continue;
        const full = try std.fs.path.join(alloc, &.{ root, entry.path });
        try checkFile(alloc, io, full, out, &summary);
    }
    return summary;
}

fn checkFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, out: *std.Io.Writer, summary: *Summary) !void {
    var norm_buf: [512]u8 = undefined;
    const rel = canonicalSrcPath(path, &norm_buf) orelse return;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(8 << 20));
    summary.scanned += 1;
    summary.findings += try checkText(rel, text, out);
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    var buf: [4096]u8 = undefined;
    var err = std.Io.File.stderr().writer(init.io, &buf);
    const out = &err.interface;
    const argv = try init.minimal.args.toSlice(alloc);
    const roots: []const []const u8 = if (argv.len > 1) argv[1..] else &.{"src"};

    var total: Summary = .{};
    for (roots) |root| {
        const one = try scanPath(alloc, init.io, root, out);
        total.scanned += one.scanned;
        total.findings += one.findings;
    }
    if (total.scanned == 0) return error.NothingToCheck;
    if (total.findings > 0) {
        try out.print("memory_writer_guard: {d} violations in {d} files\n", .{ total.findings, total.scanned });
        try out.flush();
        std.process.exit(1);
    }
    try out.print("memory_writer_guard: {d} files clean\n", .{total.scanned});
    try out.flush();
}
