//! A retained build record. Only its worker mutates provenance and result bytes.
const std = @import("std");
const builtin = @import("builtin");
const request = @import("request.zig");
const Queue = @import("queue.zig").Queue;
const Store = @import("store.zig").Store;
const source = @import("source.zig");
const execute = @import("execute.zig");
const Output = @import("output.zig").Output;
pub const Job = struct {
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    root: std.Io.Dir,
    compiler: []const u8,
    recipe: request.Recipe,
    id: u64,
    thread: ?std.Thread = null,
    cancel: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    queue: Queue = .{},
    result: [32_768]u8 = undefined,
    result_len: usize = 0,

    pub fn run(self: *Job) void {
        const allocator = self.arena.allocator();
        var record: Record = .{ .id = self.id, .compiler = self.compiler, .step = self.recipe.step, .options = self.recipe.options };
        var store: ?Store = null;
        defer if (store) |s| s.dir.close(self.io);
        self.perform(&record, &store) catch |err| {
            record.state = if (err == error.BuildCanceled) "canceled" else "failed";
            record.failure = @errorName(err);
            record.artifact = "";
            record.artifact_sha256 = "";
        };
        self.queue.mutex.lockUncancelable(self.io);
        record.stream_truncated = self.queue.truncated;
        self.queue.mutex.unlock(self.io);
        const encoded = std.json.Stringify.valueAlloc(allocator, record, .{}) catch {
            self.publish("{\"state\":\"failed\",\"failure\":\"ResultEncodingFailed\"}");
            return;
        };
        if (store) |s| s.dir.writeFile(self.io, .{ .sub_path = "result.json", .data = encoded, .flags = .{ .exclusive = true } }) catch {
            self.publish("{\"state\":\"failed\",\"failure\":\"ResultPersistenceFailed\"}");
            return;
        };
        self.publish(encoded);
    }

    fn publish(self: *Job, bytes: []const u8) void {
        const value = if (bytes.len <= self.result.len) bytes else "{\"state\":\"failed\",\"failure\":\"ResultLimit\"}";
        @memcpy(self.result[0..value.len], value);
        self.result_len = value.len;
        self.done.store(true, .release);
    }

    fn perform(self: *Job, record: *Record, store: *?Store) !void {
        const allocator = self.arena.allocator();
        const budget: request.Budget = .{ .io = self.io, .cancel = &self.cancel, .deadline = std.Io.Clock.awake.now(self.io).nanoseconds + @as(i96, self.recipe.timeout_ms) * 1_000_000 };
        try budget.check();
        store.* = try Store.open(self.root, self.io);
        const saved = &store.*.?;
        record.directory = try allocator.dupe(u8, &saved.relative);
        record.host = try @import("store.zig").hostname(allocator);
        var root_buffer: [4096]u8 = undefined;
        const root_path = root_buffer[0..try self.root.realPath(self.io, &root_buffer)];
        var version: std.ArrayList(u8) = .empty;
        defer version.deinit(std.heap.page_allocator);
        if (try execute.run(&.{ self.compiler, "version" }, self.root, budget, null, &version, &record.cleanup) != 0) return error.CompilerVersionFailed;
        record.compiler_version = try allocator.dupe(u8, std.mem.trim(u8, version.items, "\r\n "));
        const revision = try source.revision(self.root, budget);
        record.source_sha256 = try allocator.dupe(u8, &revision);
        const prefix = try std.fmt.allocPrint(allocator, "{s}/out", .{saved.relative});
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(allocator, &.{ self.compiler, "build", "-j1", "--color=off", "--prefix", prefix });
        if (self.recipe.step.len != 0) try argv.append(allocator, self.recipe.step);
        try argv.appendSlice(allocator, self.recipe.options);
        record.argv = argv.items;
        const stdout = try saved.dir.createFile(self.io, "stdout.log", .{ .exclusive = true });
        defer stdout.close(self.io);
        const stderr = try saved.dir.createFile(self.io, "stderr.log", .{ .exclusive = true });
        defer stderr.close(self.io);
        var output: Output = .{ .io = self.io, .queue = &self.queue, .root_path = root_path, .stdout = stdout, .stderr = stderr };
        record.exit_code = try execute.run(argv.items, self.root, budget, &output, null, &record.cleanup);
        if (record.exit_code != 0) return error.CompilerFailed;
        const after = try source.revision(self.root, budget);
        if (!std.mem.eql(u8, &revision, &after)) return error.SourceChanged;
        if (self.recipe.artifact.len != 0) {
            const artifact_path = try std.fmt.allocPrint(allocator, "out/{s}", .{self.recipe.artifact});
            const digest = try source.artifact(saved.dir, artifact_path, budget);
            record.artifact_sha256 = try allocator.dupe(u8, &digest);
            record.artifact = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ saved.relative, artifact_path });
        }
        try budget.check();
        record.state = "succeeded";
    }
};

const Record = struct {
    id: u64,
    state: []const u8 = "failed",
    failure: []const u8 = "",
    exit_code: i32 = -1,
    cleanup: execute.Cleanup = .not_started,
    host: []const u8 = "",
    platform: []const u8 = @tagName(builtin.os.tag) ++ "-" ++ @tagName(builtin.cpu.arch),
    compiler: []const u8,
    compiler_version: []const u8 = "",
    step: []const u8,
    options: []const []const u8,
    argv: []const []const u8 = &.{},
    directory: []const u8 = "",
    source_sha256: []const u8 = "",
    source_scope: []const u8 = "workspace regular files; excludes .git, .zig-cache, zig-out, .ra8-builds; external dependencies are not sealed",
    artifact: []const u8 = "",
    artifact_sha256: []const u8 = "",
    stream_truncated: bool = false,
};
