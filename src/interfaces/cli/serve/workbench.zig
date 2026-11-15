//! The explicitly enabled host workspace and compiler outlive each connection.
const std = @import("std");
const host = @import("ra8_host");
const rpc = @import("ra8_rpc");

pub const Workbench = struct {
    workspace: ?host.workspace.Workspace = null,
    runner: ?host.build.Runner = null,
    project: ?host.project.Project = null,

    pub fn open(self: *Workbench, io: std.Io, root: ?[]const u8, compiler: ?[]const u8) !void {
        const path = root orelse {
            if (compiler != null) return error.WorkspaceRequired;
            return;
        };
        self.workspace = try host.workspace.Workspace.open(io, path);
        errdefer self.close();
        if (compiler) |tool| self.runner = try host.build.Runner.init(io, self.workspace.?.dir, tool);
        self.project = .{ .allocator = std.heap.page_allocator, .base = &self.workspace.?, .backend_compiler = compiler orelse "" };
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
