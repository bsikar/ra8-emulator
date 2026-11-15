//! Pure preflight plan: no downloads, execution, driver installation or device access.
const std = @import("std");
const artifacts = @import("artifact.zig");
const targets = @import("target.zig");
const policy = @import("policy.zig");
pub const Request = struct {
    host: []const u8,
    target: []const u8,
    project_zig: ?[]const u8 = null,
    backend_zig: ?[]const u8 = null,
    cache_root: ?[]const u8 = null,
    offline: bool = false,
};
pub const Plan = struct {
    manifest_version: u32 = policy.version,
    policy: @TypeOf(policy.decision) = policy.decision,
    pinned_baseline: artifacts.Artifact,
    ra_sdk_reference: ?@TypeOf(artifacts.fsp_candidate),
    target: targets.Target,
    compiler_source: enum { project_override, backend_override, managed_required },
    compiler_path: []const u8,
    offline: bool,
    availability: []const u8 = "not probed; this plan does not claim an installed compiler or SDK",
    override_verification: []const u8 = "baseline archive hash does not authenticate an explicit override; measure its executable and verify version/compatibility separately",
    build_gate: []const u8 = "verify compiler/version and all project dependencies, startup/linker/SDK inputs; Zig alone is not a vendor SDK",
    debug_gate: []const u8 = "selected ELF/source revision must match; external GDB optional; hardware needs a validated probe server",
    flash_gate: []const u8 = "blocked until target flash profile, exact image, licensed tools, USB access and exclusive device reservation are verified",
    npu_gate: []const u8 = "model compilation/execution is separate from CPU firmware build; no universal model tool bundle",
};

pub fn make(allocator: std.mem.Allocator, request: Request) !Plan {
    const compiler = try artifacts.forHost(request.host);
    const target = try targets.find(request.target);
    const selected = request.project_zig orelse request.backend_zig;
    if (selected) |path| try absolute(path, request.host);
    var path: []const u8 = selected orelse "";
    if (selected == null) if (request.cache_root) |root| {
        try absolute(root, request.host);
        path = try std.fmt.allocPrint(allocator, "{s}/zig/{s}/{s}/{s}/{s}", .{ root, compiler.version, compiler.host, compiler.sha256, compiler.executable });
    };
    return .{ .pinned_baseline = compiler, .ra_sdk_reference = if (std.mem.eql(u8, target.id, "grove-vision-ai-v2")) null else artifacts.fsp_candidate, .target = target, .compiler_source = if (request.project_zig != null) .project_override else if (request.backend_zig != null) .backend_override else .managed_required, .compiler_path = path, .offline = request.offline };
}

fn absolute(path: []const u8, host: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidToolPath;
    // Plans can describe another host; validate with its path grammar, not ours.
    const windows = std.mem.eql(u8, host, "x86_64-windows");
    if (!(if (windows) std.fs.path.isAbsoluteWindows(path) else std.fs.path.isAbsolutePosix(path))) return error.InvalidToolPath;
    if (windows and std.fs.path.diskDesignatorWindows(path).len == 0) return error.InvalidToolPath;
}
