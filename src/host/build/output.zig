//! Finite compiler logs, live chunks, and complete-line structured diagnostics.
const std = @import("std");
const Queue = @import("queue.zig");
const parse = @import("diagnostic.zig").parse;
const paths = @import("../workspace/path.zig");
pub const Output = struct {
    io: std.Io,
    queue: *Queue.Queue,
    root_path: []const u8,
    stdout: std.Io.File,
    stderr: std.Io.File,
    total: usize = 0,
    line: [8192]u8 = undefined,
    used: usize = 0,
    line_overflow: bool = false,

    pub fn accept(self: *Output, kind: Queue.Kind, bytes: []const u8) !void {
        if (bytes.len > 16 * 1024 * 1024 - self.total) return error.OutputLimit;
        self.total += bytes.len;
        try (if (kind == .stdout) self.stdout else self.stderr).writeStreamingAll(self.io, bytes);
        self.queue.push(self.io, kind, bytes);
        if (kind != .stderr) return;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.flush();
            } else if (self.used < self.line.len) {
                self.line[self.used] = byte;
                self.used += 1;
            } else self.line_overflow = true;
        }
    }

    pub fn flush(self: *Output) void {
        defer {
            self.used = 0;
            self.line_overflow = false;
        }
        if (self.line_overflow) return;
        const diagnostic = parse(self.line[0..self.used]) orelse return;
        var normalized: [4096]u8 = undefined;
        var name = diagnostic.path;
        var external = false;
        if (std.fs.path.isAbsolute(name)) {
            if (name.len > self.root_path.len and std.mem.startsWith(u8, name, self.root_path) and std.mem.indexOfScalar(u8, "/\\", name[self.root_path.len]) != null) {
                name = name[self.root_path.len + 1 ..];
            } else external = true;
        }
        const relative = if (external) "" else paths.normalize(name, &normalized) catch "";
        var bytes: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&bytes);
        std.json.Stringify.value(.{ .path = relative, .external = external or relative.len == 0, .line = diagnostic.line, .column = diagnostic.column, .message = diagnostic.message }, .{}, &writer) catch return;
        self.queue.push(self.io, .diagnostic, writer.buffered());
    }
};
