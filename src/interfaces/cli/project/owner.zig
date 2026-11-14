//! The application loads verified project bytes into Session and supplies host paths.
const std = @import("std");
const dap = @import("ra8_dap");
const session = @import("ra8_session");
const Project = @import("ra8_host").project.Project;

pub const Owner = struct {
    project: *Project,
    harness: ?session.harness.Harness = null,

    pub fn close(self: *Owner) void {
        if (self.harness) |*harness| harness.deinit();
        self.harness = null;
    }

    pub fn open(context: *anyopaque, receipt: []const u8) anyerror!dap.adapter.Target {
        const self: *Owner = @ptrCast(@alignCast(context));
        if (self.harness != null) return error.TargetAlreadyLoaded;
        if (!std.mem.eql(u8, self.project.parsed.?.value.target, "ra8d2")) return error.UnsupportedProjectDebugTarget;
        const bytes = try self.project.load(receipt);
        defer self.project.allocator.free(bytes);
        self.harness = try session.harness.open(self.project.allocator, self.project.base.io, .{ .elf_bytes = bytes, .history_frames = 0 });
        const h = &self.harness.?;
        h.session().history = null;
        return .{ .session = h.session(), .images = .{ h.image(), null }, .sources = .{ .context = self.project, .pathFn = path, .checkFn = check } };
    }

    fn path(context: *anyopaque, name: []const u8, to_client: bool, into: []u8) anyerror![]const u8 {
        const project: *Project = @ptrCast(@alignCast(context));
        return project.sourceLocation(name, to_client, into);
    }

    fn check(context: *anyopaque) anyerror!void {
        const project: *Project = @ptrCast(@alignCast(context));
        return project.checkSources();
    }
};
