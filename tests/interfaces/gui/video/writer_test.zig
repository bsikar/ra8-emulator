//! FFmpeg pipe ownership at normal completion and abandoned capture cleanup.
const std = @import("std");
const builtin = @import("builtin");
const Writer = @import("gui_app").video.writer.Writer;

const Lifecycle = struct {
    closes: usize = 0,
    waits: usize = 0,
    waited_with_closed_pipe: bool = false,

    fn io(self: *Lifecycle) std.Io {
        return .{ .userdata = self, .vtable = &vtable };
    }

    const vtable: std.Io.VTable = blk: {
        var table = std.testing.io.vtable.*;
        table.fileClose = close;
        table.childWait = wait;
        break :blk table;
    };

    fn close(ctx: ?*anyopaque, files: []const std.Io.File) void {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx.?));
        self.closes += files.len;
    }

    fn wait(ctx: ?*anyopaque, child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term {
        const self: *Lifecycle = @ptrCast(@alignCast(ctx.?));
        self.waits += 1;
        // Child.wait owns every pipe still present. A closed pipe left here
        // would be closed again on Windows and POSIX alike.
        self.waited_with_closed_pipe = child.stdin != null or self.closes != 1;
        if (child.stdin != null) self.closes += 1;
        child.stdin = null;
        child.id = null;
        return .{ .exited = 0 };
    }

    fn makeChild() std.process.Child {
        return .{
            .id = if (builtin.os.tag == .windows) @ptrFromInt(8) else 8,
            .thread_handle = undefined,
            .stdin = .{
                .handle = if (builtin.os.tag == .windows) @ptrFromInt(12) else 12,
                .flags = .{ .nonblocking = false },
            },
            .stdout = null,
            .stderr = null,
            .request_resource_usage_statistics = false,
        };
    }

    fn expectSingleClose(self: Lifecycle) !void {
        try std.testing.expect(!self.waited_with_closed_pipe);
        try std.testing.expectEqual(@as(usize, 1), self.closes);
        try std.testing.expectEqual(@as(usize, 1), self.waits);
    }
};

test "finish sends EOF once before child wait and cleanup does not repeat it" {
    var life: Lifecycle = .{};
    var writer = try Writer.init(std.testing.allocator, life.io(), "unused.mp4", 30);
    writer.ffmpeg_child = Lifecycle.makeChild();
    try writer.finish();
    try std.testing.expect(writer.ffmpeg_child == null);
    try writer.finish();
    writer.deinit();
    try life.expectSingleClose();
}

test "deinit without finish relinquishes the closed pipe before child wait" {
    var life: Lifecycle = .{};
    var writer = try Writer.init(std.testing.allocator, life.io(), "unused.mp4", 30);
    writer.ffmpeg_child = Lifecycle.makeChild();
    writer.deinit();
    try life.expectSingleClose();
}
