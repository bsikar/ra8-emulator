//! One active backend build, with an explicit compiler and connection ownership.
const std = @import("std");
const Job = @import("job.zig").Job;
const request = @import("request.zig");
const heap = std.heap.page_allocator;
pub const Runner = struct {
    io: std.Io,
    root: std.Io.Dir,
    compiler: []const u8,
    next_id: u64 = 1,
    job: ?*Job = null,

    pub fn init(io: std.Io, root: std.Io.Dir, compiler: []const u8) !Runner {
        if (!@import("process.zig").supported) return error.UnsupportedPlatform;
        try validateCompiler(compiler);
        return .{ .io = io, .root = root, .compiler = compiler };
    }

    pub fn validateCompiler(compiler: []const u8) !void {
        if (!std.fs.path.isAbsolute(compiler) or compiler.len > 4096 or std.mem.indexOfScalar(u8, compiler, 0) != null) return error.InvalidCompiler;
        // A Windows rooted path such as /tools/zig.exe depends on the current
        // drive. Pin the drive or UNC share as well as the path beneath it.
        if (@import("builtin").os.tag == .windows and std.fs.path.diskDesignatorWindows(compiler).len == 0) return error.InvalidCompiler;
    }

    pub fn start(self: *Runner, asked: request.Request) !u64 {
        if (self.job) |job| if (!job.done.load(.acquire)) return error.BuildBusy;
        if (self.next_id == std.math.maxInt(u64)) return error.JobLimit;
        const job = try heap.create(Job);
        errdefer heap.destroy(job);
        var arena: std.heap.ArenaAllocator = .init(heap);
        errdefer arena.deinit();
        const recipe = try request.parse(arena.allocator(), asked);
        const compiler = try arena.allocator().dupe(u8, self.compiler);
        job.* = .{ .arena = arena, .io = self.io, .root = self.root, .compiler = compiler, .recipe = recipe, .id = self.next_id };
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.clear();
        self.job = job;
        self.next_id += 1;
        return job.id;
    }

    pub fn get(self: *Runner, id: u64) !*Job {
        const job = self.job orelse return error.UnknownBuild;
        if (id == 0 or job.id != id) return error.UnknownBuild;
        return job;
    }

    pub fn cancel(self: *Runner, id: u64) !void {
        (try self.get(id)).cancel.store(true, .release);
    }

    /// Disconnect joins only the job owned by that connection. Its record stays on disk.
    pub fn release(self: *Runner, id: u64) void {
        if (self.job) |job| if (job.id == id) self.clear();
    }

    pub fn clear(self: *Runner) void {
        const job = self.job orelse return;
        job.cancel.store(true, .release);
        if (job.thread) |thread| thread.join();
        job.arena.deinit();
        heap.destroy(job);
        self.job = null;
    }
};
