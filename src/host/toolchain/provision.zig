//! Explicit setup and network-free admission of immutable compiler generations.
const builtin = @import("builtin");
const std = @import("std");

const archive = @import("archive.zig");
const artifacts = @import("artifact.zig");
const check = @import("check.zig");
const digest = @import("digest.zig");
const manifests = @import("manifest.zig");
const ownership = @import("ownership.zig");
const paths = @import("paths.zig");
const planning = @import("plan.zig");
const Tree = @import("tree.zig").Tree;

pub const Request = struct {
    plan: planning.Request,
    archive_path: ?[]const u8 = null,
    download: bool = false,
};
pub const Result = struct {
    manifest_version: u32 = 1,
    compiler_path: []const u8,
    compiler_sha256: [64]u8,
    compiler_version: []const u8,
    source: enum { project_override, backend_override, managed },
    network_used: bool = false,
    verified_files: u32 = 0,
    verified_bytes: u64 = 0,
};

pub fn nativeHost() ![]const u8 {
    return switch (builtin.os.tag) {
        .linux => if (builtin.cpu.arch == .x86_64) "x86_64-linux" else error.UnsupportedHost,
        .windows => if (builtin.cpu.arch == .x86_64) "x86_64-windows" else error.UnsupportedHost,
        .macos => if (builtin.cpu.arch == .aarch64) "aarch64-macos" else if (builtin.cpu.arch == .x86_64)
            "x86_64-macos"
        else
            error.UnsupportedHost,
        else => error.UnsupportedHost,
    };
}

fn plan(gpa: std.mem.Allocator, request: planning.Request) !planning.Plan {
    if (!std.mem.eql(u8, request.host, try nativeHost())) return error.ExecutionHostMismatch;
    return planning.make(gpa, request);
}

/// No network or fallback. The caller owns result.compiler_path.
pub fn resolve(gpa: std.mem.Allocator, io: std.Io, request: planning.Request) !Result {
    const selected = try plan(gpa, request);
    defer if (selected.compiler_source == .managed_required and selected.compiler_path.len != 0) {
        gpa.free(selected.compiler_path);
    };
    if (selected.compiler_source == .managed_required) {
        return admit(gpa, io, request.cache_root orelse return error.ManagedCacheRequired, selected.pinned_baseline);
    }
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try std.Io.Dir.cwd().realPathFile(io, selected.compiler_path, &path_buffer)];
    try check.version(io, .cwd(), path, selected.pinned_baseline.version);
    const compiler = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
    defer compiler.close(io);
    if ((try compiler.stat(io)).kind != .file) return error.InvalidCompiler;
    const hash = try digest.file(io, compiler, 512_000_000);
    return .{
        .compiler_path = try gpa.dupe(u8, path),
        .compiler_sha256 = hash,
        .compiler_version = selected.pinned_baseline.version,
        .source = if (selected.compiler_source == .project_override) .project_override else .backend_override,
    };
}

pub fn setup(gpa: std.mem.Allocator, io: std.Io, request: Request) !Result {
    const selected = try plan(gpa, request.plan);
    defer if (selected.compiler_source == .managed_required and selected.compiler_path.len != 0) {
        gpa.free(selected.compiler_path);
    };
    if (selected.compiler_source != .managed_required) return resolve(gpa, io, request.plan);
    if (request.download and (request.plan.offline or request.archive_path != null)) return error.SetupPolicyConflict;
    const root = request.plan.cache_root orelse return error.ManagedCacheRequired;
    var dir = try paths.cache(io, root, true);
    defer dir.close(io);
    const lock = try acquire(io, dir);
    defer lock.close(io);
    const artifact = selected.pinned_baseline;
    const relative = try generation(gpa, artifact);
    defer gpa.free(relative);
    if (dir.statFile(io, relative, .{ .follow_symlinks = false })) |_| {
        return admit(gpa, io, root, artifact);
    } else |err| {
        if (err != error.FileNotFound) return err;
    }
    if (request.archive_path == null and !request.download) return error.OfflineArchiveRequired;
    try install(gpa, io, dir, root, relative, artifact, request);
    var result = try admit(gpa, io, root, artifact);
    result.network_used = request.download;
    return result;
}

pub fn generation(gpa: std.mem.Allocator, artifact: artifacts.Artifact) ![]u8 {
    return std.fmt.allocPrint(gpa, "zig/{s}/{s}/{s}", .{ artifact.version, artifact.host, artifact.sha256 });
}

fn acquire(io: std.Io, root: std.Io.Dir) !std.Io.File {
    const file = created: {
        const fresh = root.createFile(io, ".provision.lock", .{
            .read = true,
            .exclusive = true,
            .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
        }) catch |err| switch (err) {
            error.PathAlreadyExists => break :created try root.openFile(io, ".provision.lock", .{
                .mode = .read_write,
                .follow_symlinks = false,
                .resolve_beneath = true,
            }),
            else => return err,
        };
        errdefer fresh.close(io);
        try ownership.makeFilePrivate(io, root, ".provision.lock", fresh);
        break :created fresh;
    };
    errdefer file.close(io);
    try ownership.file(io, file);
    const info = try file.stat(io);
    if (info.kind != .file or info.nlink != 1) return error.UnsafeCacheEntry;
    if (!try file.tryLock(io, .exclusive)) return error.ProvisionBusy;
    return file;
}

fn install(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    absolute_root: []const u8,
    relative: []const u8,
    artifact: artifacts.Artifact,
    request: Request,
) !void {
    const parent = std.fs.path.dirname(relative).?;
    var parent_dir = try paths.descend(io, root, parent, true);
    defer parent_dir.close(io);
    var random: [16]u8 = undefined;
    std.Io.random(io, &random);
    const stage_name = try std.fmt.allocPrint(gpa, ".stage-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer gpa.free(stage_name);
    try parent_dir.createDir(io, stage_name, paths.private);
    var stage = try parent_dir.openDir(io, stage_name, .{ .iterate = true, .follow_symlinks = false });
    var open = true;
    defer if (open) stage.close(io);
    try ownership.makePrivate(io, stage);
    const file_mode: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
    const file = try stage.createFile(io, ".archive", .{
        .read = true,
        .exclusive = true,
        .permissions = file_mode,
    });
    var file_open = true;
    defer if (file_open) file.close(io);
    try ownership.makeFilePrivate(io, stage, ".archive", file);
    try input(gpa, io, artifact, file, request);
    const prefix = std.fs.path.dirname(artifact.executable).?;
    var tree = Tree.init(gpa, io, stage, true, prefix);
    defer tree.deinit();
    try archive.walk(file, artifact, &tree);
    if (artifacts.manifestSha256(artifact)) |expected| {
        if (!std.mem.eql(u8, &digest.bytes(tree.manifest.items), expected)) {
            return error.CacheManifestMismatch;
        }
    }
    {
        const manifest = try stage.createFile(io, ".manifest", .{
            .read = true,
            .exclusive = true,
            .permissions = file_mode,
        });
        defer manifest.close(io);
        try ownership.makeFilePrivate(io, stage, ".manifest", manifest);
        try manifest.writeStreamingAll(io, tree.manifest.items);
        try manifest.sync(io);
    }
    const compiler = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}/{s}", .{
        absolute_root, parent, stage_name, artifact.executable,
    });
    defer gpa.free(compiler);
    try check.version(io, stage, compiler, artifact.version);
    try smoke(gpa, io, root, compiler);
    file.close(io);
    file_open = false;
    stage.close(io);
    open = false;
    // No mutable selector or marker authorizes a generation: only this complete
    // directory rename publishes it. Older pinned generations stay untouched.
    try parent_dir.rename(stage_name, parent_dir, artifact.sha256, io);
}

fn input(
    gpa: std.mem.Allocator,
    io: std.Io,
    artifact: artifacts.Artifact,
    output: std.Io.File,
    request: Request,
) !void {
    if (request.archive_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.InvalidToolPath;
        const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
        defer file.close(io);
        try archive.verify(io, file, artifact);
        var buffer: [65536]u8 = undefined;
        var offset: u64 = 0;
        while (offset < artifact.archive_bytes) {
            const part = buffer[0..@intCast(@min(buffer.len, artifact.archive_bytes - offset))];
            if (try file.readPositionalAll(io, part, offset) != part.len) return error.ArchiveSizeMismatch;
            try output.writePositionalAll(io, part, offset);
            offset += part.len;
        }
        try output.sync(io);
        return;
    }
    if (!request.download or request.plan.offline) return error.OfflineArchiveRequired;
    try archive.download(gpa, io, artifact, output);
}

fn smoke(gpa: std.mem.Allocator, io: std.Io, root: std.Io.Dir, compiler: []const u8) !void {
    var random: [16]u8 = undefined;
    std.Io.random(io, &random);
    const name = try std.fmt.allocPrint(gpa, ".probe-{s}", .{std.fmt.bytesToHex(random, .lower)});
    defer gpa.free(name);
    try root.createDir(io, name, paths.private);
    defer root.deleteTree(io, name) catch |err| {
        std.log.warn("toolchain probe cleanup: {s}", .{@errorName(err)});
    };
    var dir = try root.openDir(io, name, .{});
    defer dir.close(io);
    try ownership.makePrivate(io, dir);
    try check.smoke(io, dir, compiler);
}

pub fn admit(gpa: std.mem.Allocator, io: std.Io, root: []const u8, artifact: artifacts.Artifact) !Result {
    var cache = try paths.cache(io, root, false);
    defer cache.close(io);
    const relative = try generation(gpa, artifact);
    defer gpa.free(relative);
    var installed = try paths.descend(io, cache, relative, false);
    defer installed.close(io);
    const file = try paths.regular(io, installed, ".archive");
    defer file.close(io);
    const record = try paths.regular(io, installed, ".manifest");
    defer record.close(io);
    var tree = Tree.init(gpa, io, installed, false, std.fs.path.dirname(artifact.executable).?);
    defer tree.deinit();
    if (artifacts.manifestSha256(artifact)) |expected| {
        try archive.verify(io, file, artifact);
        const bytes = try manifests.read(gpa, io, record);
        defer gpa.free(bytes);
        try manifests.verify(bytes, expected, &tree);
    } else {
        try archive.walk(file, artifact, &tree);
        const bytes = try manifests.read(gpa, io, record);
        defer gpa.free(bytes);
        if (!std.mem.eql(u8, bytes, tree.manifest.items)) return error.CacheManifestMismatch;
    }
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ root, relative, artifact.executable });
    errdefer gpa.free(path);
    try check.version(io, installed, path, artifact.version);
    const compiler = try paths.regular(io, installed, artifact.executable);
    defer compiler.close(io);
    return .{
        .compiler_path = path,
        .compiler_sha256 = try digest.file(io, compiler, 512_000_000),
        .compiler_version = artifact.version,
        .source = .managed,
        .verified_files = tree.entries,
        .verified_bytes = tree.bytes,
    };
}

/// An RPC-writable workspace must never contain or be inside the managed cache.
pub fn separate(io: std.Io, workspace: std.Io.Dir, root: []const u8) !void {
    var cache = try paths.cache(io, root, false);
    defer cache.close(io);
    var workspace_buffer: [4096]u8 = undefined;
    var cache_buffer: [4096]u8 = undefined;
    const workspace_path = workspace_buffer[0..try workspace.realPath(io, &workspace_buffer)];
    const cache_path = cache_buffer[0..try cache.realPath(io, &cache_buffer)];
    if (within(workspace_path, cache_path) or within(cache_path, workspace_path)) return error.CacheWorkspaceOverlap;
}

fn within(parent: []const u8, child: []const u8) bool {
    if (child.len < parent.len) return false;
    const prefix = child[0..parent.len];
    const equal = if (builtin.os.tag == .windows)
        std.ascii.eqlIgnoreCase(parent, prefix)
    else
        std.mem.eql(u8, parent, prefix);
    if (!equal) return false;
    return child.len == parent.len or parent[parent.len - 1] == '/' or parent[parent.len - 1] == '\\' or
        child[parent.len] == '/' or child[parent.len] == '\\';
}
