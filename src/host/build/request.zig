//! A bounded Zig recipe. The backend chooses the compiler and output directories.
const std = @import("std");
const path = @import("../workspace/path.zig");
pub const Request = struct { step: []const u8, options: []const u8, artifact: []const u8, timeout_ms: u32 };
pub const Recipe = struct { step: []const u8, options: []const []const u8, artifact: []const u8, timeout_ms: u32 };

pub fn parse(allocator: std.mem.Allocator, request: Request) !Recipe {
    if (request.step.len > 64 or request.options.len > 4096 or request.artifact.len > 512 or request.timeout_ms < 100 or request.timeout_ms > 600_000) return error.InvalidRecipe;
    for (request.step) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.InvalidRecipe;
    // A leading dash would be a compiler option rather than a build step.
    if (std.mem.startsWith(u8, request.step, "-")) return error.InvalidRecipe;
    const parsed = std.json.parseFromSlice([]const []const u8, allocator, request.options, .{ .allocate = .alloc_always }) catch return error.InvalidRecipe;
    defer parsed.deinit();
    if (parsed.value.len > 16) return error.InvalidRecipe;
    const options = try allocator.alloc([]const u8, parsed.value.len);
    for (parsed.value, options) |value, *out| {
        if (value.len < 3 or value.len > 256 or !std.mem.startsWith(u8, value, "-D") or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidRecipe;
        out.* = try allocator.dupe(u8, value);
    }
    var buffer: [512]u8 = undefined;
    const artifact = try path.normalize(request.artifact, &buffer);
    return .{ .step = try allocator.dupe(u8, request.step), .options = options, .artifact = try allocator.dupe(u8, artifact), .timeout_ms = request.timeout_ms };
}

pub const Budget = struct {
    io: std.Io,
    cancel: *const std.atomic.Value(bool),
    deadline: i96,
    pub fn check(self: Budget) !void {
        if (self.cancel.load(.acquire)) return error.BuildCanceled;
        if (std.Io.Clock.awake.now(self.io).nanoseconds >= self.deadline) return error.BuildTimeout;
    }
};
