//! Bounded compiler admission probes reuse the backend process-tree owner.
const std = @import("std");

const execute = @import("../build/execute.zig");
const request = @import("../build/request.zig");

fn run(io: std.Io, cwd: std.Io.Dir, argv: []const []const u8, seconds: u32) ![]u8 {
    var cancel: std.atomic.Value(bool) = .init(false);
    const budget: request.Budget = .{
        .io = io,
        .cancel = &cancel,
        .deadline = std.Io.Clock.awake.now(io).nanoseconds + @as(i96, seconds) * 1_000_000_000,
    };
    var capture: std.ArrayList(u8) = .empty;
    errdefer capture.deinit(std.heap.page_allocator);
    var cleanup: execute.Cleanup = .not_started;
    if (try execute.run(argv, cwd, budget, null, &capture, &cleanup) != 0) return error.CompilerProbeFailed;
    if (cleanup != .complete) return error.CompilerCleanupFailed;
    return capture.toOwnedSlice(std.heap.page_allocator);
}

pub fn version(io: std.Io, cwd: std.Io.Dir, compiler: []const u8, expected: []const u8) !void {
    const output = try run(io, cwd, &.{ compiler, "version" }, 10);
    defer std.heap.page_allocator.free(output);
    if (!std.mem.eql(u8, std.mem.trim(u8, output, "\r\n "), expected)) return error.CompilerVersionMismatch;
}

pub fn smoke(io: std.Io, cwd: std.Io.Dir, compiler: []const u8) !void {
    try cwd.writeFile(io, .{ .sub_path = "probe.zig", .data = "const std = @import(\"std\");\n" ++
        "export fn rotate(v: u32) u32 { return std.math.rotl(u32, v, 3); }\n" });
    const output = try run(io, cwd, &.{
        compiler,           "build-obj",          "probe.zig",   "-target",     "thumb-freestanding-eabi",
        "-mcpu=cortex_m33", "-femit-bin=probe.o", "--cache-dir", "local-cache", "--global-cache-dir",
        "global-cache",
    }, 240);
    defer std.heap.page_allocator.free(output);
    const file = try cwd.openFile(io, "probe.o", .{ .follow_symlinks = false });
    defer file.close(io);
    var magic: [4]u8 = undefined;
    if (try file.readPositionalAll(io, &magic, 0) != magic.len or !std.mem.eql(u8, &magic, "\x7fELF")) {
        return error.CompilerSmokeFailed;
    }
}
