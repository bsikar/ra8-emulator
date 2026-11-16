//! An opened project owns its workspace and current build, never debugger state.
const std = @import("std");

const build = @import("../build/root.zig");
const config = @import("config.zig");
const files = @import("files.zig");
const handoff = @import("handoff.zig");
const receipt = @import("receipt.zig");
const sources = @import("sources.zig");
const Workspace = @import("../workspace/workspace.zig").Workspace;

pub const Project = struct {
    allocator: std.mem.Allocator,
    base: *Workspace,
    backend_compiler: []const u8,
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
        const compiler = parsed.value.compiler orelse if (self.backend_compiler.len != 0)
            self.backend_compiler
        else
            return error.CompilerRequired;
        const runner = try build.Runner.init(self.base.io, dir, compiler);
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
