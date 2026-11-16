//! An opened project owns its workspace and current build, never debugger state.
const std = @import("std");

const build = @import("../build/root.zig");
const config = @import("config.zig");
const files = @import("files.zig");
const handoff = @import("handoff.zig");
const planning = @import("../toolchain/plan.zig");
const provision = @import("../toolchain/provision.zig");
const receipt = @import("receipt.zig");
const sources = @import("sources.zig");
const Workspace = @import("../workspace/workspace.zig").Workspace;

const Selected = struct { path: []const u8, version: []const u8 };

pub const Project = struct {
    allocator: std.mem.Allocator,
    base: *Workspace,
    backend_compiler: []const u8,
    toolchain_cache: ?[]const u8 = null,
    managed: ?provision.Result = null,
    override_path: ?[]u8 = null,
    admitted_fresh: bool = false,
    parsed: ?std.json.Parsed(config.Config) = null,
    workspace: ?Workspace = null,
    runner: ?build.Runner = null,
    root_path: []const u8 = "",
    config_name: []const u8 = "",
    config_sha256: [64]u8 = undefined,
    latest_recipe: ?config.Recipe = null,
    latest_id: u64 = 0,
    receipt_path: [512]u8 = undefined,
    bound_source: ?[64]u8 = null,

    pub fn open(self: *Project, name: []const u8) !void {
        if (self.parsed != null) return error.ProjectAlreadyOpen;
        const bytes = try files.read(self.allocator, self.base.io, self.base.dir, name, 65_536);
        defer self.allocator.free(bytes);
        var parsed = try config.parse(self.allocator, bytes);
        errdefer parsed.deinit();
        const dir = try files.directory(self.base.io, self.base.dir, parsed.value.root);
        errdefer dir.close(self.base.io);
        var buffer: [4096]u8 = undefined;
        const root_path = try self.allocator.dupe(u8, buffer[0..try dir.realPath(self.base.io, &buffer)]);
        errdefer self.allocator.free(root_path);
        const config_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(config_name);
        const selected = try self.chooseCompiler(parsed.value);
        errdefer self.releaseCompiler();
        var runner = try build.Runner.init(self.base.io, dir, selected.path);
        runner.expected_version = selected.version;
        if (self.managed != null) runner.admission = .{ .context = self, .check = checkManaged };
        self.parsed = parsed;
        self.workspace = .{ .dir = dir, .io = self.base.io };
        self.root_path = root_path;
        self.config_name = config_name;
        self.runner = runner;
        self.config_sha256 = files.digest(bytes);
    }

    pub fn close(self: *Project) void {
        if (self.runner) |*runner| runner.clear();
        if (self.workspace) |*workspace| workspace.close();
        if (self.parsed) |parsed| parsed.deinit();
        if (self.root_path.len != 0) self.allocator.free(self.root_path);
        if (self.config_name.len != 0) self.allocator.free(self.config_name);
        self.parsed = null;
        self.workspace = null;
        self.runner = null;
        self.root_path = "";
        self.config_name = "";
        self.latest_recipe = null;
        self.latest_id = 0;
        self.bound_source = null;
        self.releaseCompiler();
    }

    fn chooseCompiler(self: *Project, value: config.Config) !Selected {
        const selected = try planning.make(self.allocator, .{
            .host = try provision.nativeHost(),
            .target = value.target,
            .project_zig = value.compiler,
            .backend_zig = if (self.backend_compiler.len == 0) null else self.backend_compiler,
            .cache_root = self.toolchain_cache,
            .offline = true,
        });
        defer if (selected.compiler_source == .managed_required and selected.compiler_path.len != 0) {
            self.allocator.free(selected.compiler_path);
        };
        if (selected.compiler_source == .managed_required) {
            const cache = self.toolchain_cache orelse return error.ManagedCacheRequired;
            try provision.separate(self.base.io, self.base.dir, cache);
            self.managed = try provision.admit(self.allocator, self.base.io, cache, selected.pinned_baseline);
            self.admitted_fresh = true;
            return .{ .path = self.managed.?.compiler_path, .version = selected.pinned_baseline.version };
        }
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = if (std.Io.Dir.cwd().realPathFile(self.base.io, selected.compiler_path, &path_buffer)) |n|
            path_buffer[0..n]
        else |_|
            selected.compiler_path;
        self.override_path = try self.allocator.dupe(u8, resolved);
        return .{ .path = self.override_path.?, .version = selected.pinned_baseline.version };
    }

    fn releaseCompiler(self: *Project) void {
        if (self.managed) |held| self.allocator.free(held.compiler_path);
        if (self.override_path) |path| self.allocator.free(path);
        self.managed = null;
        self.override_path = null;
        self.admitted_fresh = false;
    }

    fn checkManaged(context: *anyopaque) !void {
        const self: *Project = @ptrCast(@alignCast(context));
        if (@atomicRmw(bool, &self.admitted_fresh, .Xchg, false, .acq_rel)) return;
        const result = try provision.resolve(std.heap.page_allocator, self.base.io, .{
            .host = try provision.nativeHost(),
            .target = self.parsed.?.value.target,
            .project_zig = self.parsed.?.value.compiler,
            .backend_zig = if (self.backend_compiler.len == 0) null else self.backend_compiler,
            .cache_root = self.toolchain_cache,
            .offline = true,
        });
        defer std.heap.page_allocator.free(result.compiler_path);
        if (!std.mem.eql(u8, result.compiler_path, self.managed.?.compiler_path) or
            !std.mem.eql(u8, &result.compiler_sha256, &self.managed.?.compiler_sha256)) return error.CompilerChanged;
    }

    pub fn start(self: *Project, name: []const u8) !u64 {
        const parsed = self.parsed orelse return error.ProjectNotOpen;
        try self.checkConfig();
        const selected = try config.findRecipe(parsed.value, name);
        if ((try self.workspace.?.stat("build.zig")).kind != .file) return error.ProjectBuildFileRequired;
        const id = try self.runner.?.start(selected.request());
        self.latest_recipe = selected;
        self.latest_id = id;
        self.bound_source = null;
        return id;
    }

    pub fn budget(self: *Project, cancel: *const std.atomic.Value(bool)) build.request.Budget {
        return .{
            .io = self.base.io,
            .cancel = cancel,
            .deadline = std.Io.Clock.awake.now(self.base.io).nanoseconds + 5_000_000_000,
        };
    }

    pub fn checkConfig(self: *Project) !void {
        const bytes = try files.read(self.allocator, self.base.io, self.base.dir, self.config_name, 65_536);
        defer self.allocator.free(bytes);
        if (!std.mem.eql(u8, &files.digest(bytes), &self.config_sha256)) return error.ProjectConfigChanged;
    }

    pub fn prepare(self: *Project, id: u64) ![]const u8 {
        if (id == 0 or id != self.latest_id) return error.UnknownBuild;
        const job = try self.runner.?.get(id);
        if (!job.done.load(.acquire)) return error.BuildBusy;
        var parsed = try receipt.record(self.allocator, job.result[0..job.result_len]);
        defer parsed.deinit();
        const record = parsed.value;
        const selected = self.latest_recipe orelse return error.UnknownBuild;
        const value: receipt.Receipt = .{
            .config_sha256 = &self.config_sha256,
            .recipe = selected.name,
            .target = self.parsed.?.value.target,
            .build_id = id,
            .directory = record.directory,
            .artifact = record.artifact,
            .artifact_sha256 = record.artifact_sha256,
            .source_sha256 = record.source_sha256,
            .compiler = record.compiler,
            .compiler_version = record.compiler_version,
        };
        const verified = try self.verify(value);
        self.allocator.free(verified);
        const bytes = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(bytes);
        const name = try std.fmt.bufPrint(&self.receipt_path, "{s}/project.json", .{record.directory});
        try handoff.save(self, name, bytes);
        return name;
    }

    pub fn load(self: *Project, name: []const u8) ![]u8 {
        if (self.parsed == null) return error.ProjectNotOpen;
        const bytes = try files.read(self.allocator, self.base.io, self.workspace.?.dir, name, 32_768);
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(
            receipt.Receipt,
            self.allocator,
            bytes,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();
        const elf = try self.verify(parsed.value);
        self.bound_source = parsed.value.source_sha256[0..64].*;
        return elf;
    }

    fn verify(self: *Project, value: receipt.Receipt) ![]u8 {
        return handoff.verify(self, value);
    }

    pub fn sourcePath(self: *Project, name: []const u8, to_client: bool, into: []u8) ![]const u8 {
        return sources.translate(self, name, to_client, into);
    }

    pub fn sourceLocation(self: *Project, name: []const u8, to_client: bool, into: []u8) ![]const u8 {
        return sources.location(self, name, to_client, into);
    }

    pub fn checkSources(self: *Project) !void {
        return sources.check(self);
    }
};
