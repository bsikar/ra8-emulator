//! The explicitly enabled host workspace and compiler outlive each connection.
const std = @import("std");

const host = @import("ra8_host");
const rpc = @import("ra8_rpc");

pub const Workbench = struct {
    workspace: ?host.workspace.Workspace = null,
    runner: ?host.build.Runner = null,
    project: ?host.project.Project = null,
    cache_root: ?[]const u8 = null,
    managed: ?host.toolchain.provision.Result = null,
    compiler_owned: ?[]u8 = null,
    admitted_fresh: bool = false,

    pub fn open(self: *Workbench, io: std.Io, root: ?[]const u8, compiler: ?[]const u8) !void {
        return self.openWithCache(io, root, compiler, null);
    }

    pub fn openWithCache(
        self: *Workbench,
        io: std.Io,
        root: ?[]const u8,
        compiler: ?[]const u8,
        cache_root: ?[]const u8,
    ) !void {
        const path = root orelse {
            if (compiler != null or cache_root != null) return error.WorkspaceRequired;
            return;
        };
        self.workspace = try host.workspace.Workspace.open(io, path);
        errdefer self.close();
        self.cache_root = cache_root;
        try self.initRunner(io, compiler, cache_root);
        self.project = .{
            .allocator = std.heap.page_allocator,
            .base = &self.workspace.?,
            .backend_compiler = compiler orelse "",
            .toolchain_cache = cache_root,
        };
    }

    fn initRunner(self: *Workbench, io: std.Io, compiler: ?[]const u8, cache_root: ?[]const u8) !void {
        if (compiler) |tool| {
            var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = if (std.Io.Dir.cwd().realPathFile(io, tool, &path_buffer)) |n|
                path_buffer[0..n]
            else |_|
                tool;
            self.compiler_owned = try std.heap.page_allocator.dupe(u8, resolved);
            self.runner = try host.build.Runner.init(io, self.workspace.?.dir, self.compiler_owned.?);
            self.runner.?.expected_version = "0.17.0";
            return;
        }
        const cache = cache_root orelse return;
        try host.toolchain.provision.separate(io, self.workspace.?.dir, cache);
        self.managed = try host.toolchain.provision.resolve(std.heap.page_allocator, io, .{
            .host = try host.toolchain.provision.nativeHost(),
            .target = "ra8d2",
            .cache_root = cache,
            .offline = true,
        });
        self.admitted_fresh = true;
        self.runner = try host.build.Runner.init(io, self.workspace.?.dir, self.managed.?.compiler_path);
        self.runner.?.expected_version = self.managed.?.compiler_version;
        self.runner.?.admission = .{ .context = self, .check = checkManaged };
    }

    pub fn bind(self: *Workbench, context: anytype) void {
        if (self.workspace) |*workspace| context.workspace = workspace;
        if (self.runner) |*runner| context.build_runner = runner;
        context.project_base_workspace = context.workspace;
        context.project_base_runner = context.build_runner;
        if (self.project) |*project| context.project = project;
    }

    pub fn close(self: *Workbench) void {
        if (self.project) |*project| project.close();
        self.project = null;
        if (self.runner) |*runner| runner.clear();
        if (self.workspace) |*workspace| workspace.close();
        self.runner = null;
        self.workspace = null;
        if (self.managed) |held| std.heap.page_allocator.free(held.compiler_path);
        if (self.compiler_owned) |path| std.heap.page_allocator.free(path);
        self.managed = null;
        self.compiler_owned = null;
        self.admitted_fresh = false;
        self.cache_root = null;
    }

    fn checkManaged(context: *anyopaque) !void {
        const self: *Workbench = @ptrCast(@alignCast(context));
        if (@atomicRmw(bool, &self.admitted_fresh, .Xchg, false, .acq_rel)) return;
        const result = try host.toolchain.provision.resolve(std.heap.page_allocator, self.workspace.?.io, .{
            .host = try host.toolchain.provision.nativeHost(),
            .target = "ra8d2",
            .cache_root = self.cache_root,
            .offline = true,
        });
        defer std.heap.page_allocator.free(result.compiler_path);
        if (!std.mem.eql(u8, result.compiler_path, self.managed.?.compiler_path) or
            !std.mem.eql(u8, &result.compiler_sha256, &self.managed.?.compiler_sha256)) return error.CompilerChanged;
    }

    pub fn unbind(_: *Workbench, context: anytype) void {
        rpc.project.forget(context);
        rpc.build.forget(context);
        context.project = null;
        context.workspace = null;
        context.build_runner = null;
        context.project_base_workspace = null;
        context.project_base_runner = null;
    }
};
