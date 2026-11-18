//! Runs one J-Link tool to completion within a deadline or cancellation flag,
//! capturing its combined output into a caller buffer. The whole process tree
//! is stopped when cancelled or past the deadline, so a wedged probe never
//! holds the caller.
const std = @import("std");

const pipe = @import("../build/pipe.zig");
const Process = @import("../build/process.zig").Process;

pub const Result = struct { code: i32, output: []const u8 };

pub fn run(io: std.Io, argv: []const []const u8, out: []u8, timeout_ms: u32) !Result {
    return runWithCancel(io, argv, out, timeout_ms, null);
}

pub fn runWithCancel(
    io: std.Io,
    argv: []const []const u8,
    out: []u8,
    timeout_ms: u32,
    cancel: ?*const std.atomic.Value(bool),
) !Result {
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + @as(i96, timeout_ms) * std.time.ns_per_ms;
    var process = try Process.spawn(io, argv, std.Io.Dir.cwd());
    var used: usize = 0;
    const wait_result = waitBounded(&process, io, deadline, cancel, out, &used);
    const term = process.finish();
    try process.close();
    try wait_result;
    const done = try term;
    return .{ .code = switch (done) {
        .exited => |code| @intCast(code),
        else => -1,
    }, .output = out[0..used] };
}

fn waitBounded(
    process: *Process,
    io: std.Io,
    deadline: i96,
    cancel: ?*const std.atomic.Value(bool),
    out: []u8,
    used: *usize,
) !void {
    var eof = [2]bool{ false, false };
    while (true) {
        if (cancel) |flag| {
            if (flag.load(.acquire)) return error.Canceled;
        }
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return error.ProbeTimeout;
        const exited = try process.exited();
        used.* = try drain(process, &eof, out, used.*);
        if (exited and eof[0] and eof[1]) return;
        if (exited) try process.stopTree();
        try std.Io.sleep(io, .fromMilliseconds(5), .awake);
    }
}

fn drain(process: *Process, eof: *[2]bool, out: []u8, start: usize) !usize {
    var used = start;
    for ([_]?std.Io.File{ process.child.stdout, process.child.stderr }, 0..) |maybe, index| {
        if (eof[index]) continue;
        const file = maybe orelse return error.MissingOutputPipe;
        var bytes: [4096]u8 = undefined;
        const count = try pipe.read(process.io, file, &bytes) orelse continue;
        if (count == 0) {
            eof[index] = true;
            continue;
        }
        if (count > out.len - used) return error.ProbeOutputLimit;
        @memcpy(out[used..][0..count], bytes[0..count]);
        used += count;
    }
    return used;
}
