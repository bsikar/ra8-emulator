//! The explicitly enabled host workspace and compiler outlive each connection.
const std = @import("std");
const host = @import("ra8_host");
pub const Workbench = struct {
    workspace: ?host.workspace.Workspace = null,
    runner: ?host.build.Runner = null,

    pub fn open(self: *Workbench, io: std.Io, root: ?[]const u8, compiler: ?[]const u8) !void {
        const path = root orelse {
            if (compiler != null) return error.WorkspaceRequired;
            return;
        };
        self.workspace = try host.workspace.Workspace.open(io, path);
        errdefer self.close();
        if (compiler) |tool| self.runner = try host.build.Runner.init(io, self.workspace.?.dir, tool);
    }

    pub fn bind(self: *Workbench, context: anytype) void {
        if (self.workspace) |*workspace| context.workspace = workspace;
        if (self.runner) |*runner| context.build_runner = runner;
    }

    pub fn close(self: *Workbench) void {
        if (self.runner) |*runner| runner.clear();
        if (self.workspace) |*workspace| workspace.close();
        self.runner = null;
        self.workspace = null;
    }
};
