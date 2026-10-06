//! The RPC byte transport over a child process's pipes (RA8EMU-196): the
//! child is a `serve --stdio`, run here or behind ssh.
const std = @import("std");
const rpc = @import("ra8_rpc");
const Stdio = @import("stdio_transport.zig").Stdio;

pub const Child = struct {
    process: std.process.Child,
    pipes: Stdio = .{},

    /// Start `argv` with its stdin and stdout as the link. Its stderr stays
    /// ours, so a remote's complaint reaches the user. `argv` must outlive
    /// the child.
    pub fn spawn(self: *Child, allocator: std.mem.Allocator, argv: []const []const u8) !void {
        self.* = .{ .process = std.process.Child.init(argv, allocator) };
        self.process.stdin_behavior = .Pipe;
        self.process.stdout_behavior = .Pipe;
        self.process.stderr_behavior = .Inherit;
        try self.process.spawn();
        self.pipes = .{ .input = self.process.stdout.?.handle, .output = self.process.stdin.?.handle };
    }

    pub fn transport(self: *Child) rpc.Transport {
        return self.pipes.transport();
    }

    /// Close the child's stdin, which ends `serve`, then wait for it.
    pub fn close(self: *Child) void {
        if (self.process.stdin) |*file| file.close();
        self.process.stdin = null;
        _ = self.process.wait() catch {};
    }
};
