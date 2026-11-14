//! One thread owns the child from spawn through pipe drain and reap.
const std = @import("std");
const Process = @import("process.zig").Process;
const pipe = @import("pipe.zig");
const Budget = @import("request.zig").Budget;
const Output = @import("output.zig").Output;
pub const Cleanup = enum { not_started, complete, unknown };

pub fn run(argv: []const []const u8, root: std.Io.Dir, budget: Budget, output: ?*Output, capture: ?*std.ArrayList(u8), cleanup: *Cleanup) !i32 {
    cleanup.* = .not_started;
    try budget.check();
    var process = try Process.spawn(budget.io, argv, root);
    cleanup.* = .unknown;
    var closed = false;
    defer if (!closed) {
        if (process.close()) |_| {
            cleanup.* = .complete;
        } else |_| {
            cleanup.* = .unknown;
        }
    };
    var failure: ?anyerror = null;
    var eof = [2]bool{ false, false };
    while (!eof[0] or !eof[1]) {
        budget.check() catch |err| {
            failure = err;
            break;
        };
        const exited = process.exited() catch |err| {
            failure = err;
            break;
        };
        if (exited) process.stopTree() catch |err| {
            failure = err;
            break;
        };
        drain(&process, &eof, output, capture) catch |err| {
            failure = err;
            break;
        };
        if (eof[0] and eof[1] and exited) break;
        std.Io.sleep(budget.io, .fromMilliseconds(5), .awake) catch |err| {
            failure = err;
            break;
        };
    }
    // Closed pipes do not imply the process has ended.
    while (failure == null and !try process.exited()) {
        budget.check() catch |err| {
            failure = err;
            break;
        };
        try std.Io.sleep(budget.io, .fromMilliseconds(5), .awake);
    }
    const term = try process.finish();
    process.close() catch |err| {
        closed = true;
        return err;
    };
    closed = true;
    cleanup.* = .complete;
    if (output) |out| out.flush();
    if (failure) |err| return err;
    return switch (term) {
        .exited => |code| @intCast(code),
        else => -1,
    };
}

fn drain(process: *Process, eof: *[2]bool, output: ?*Output, capture: ?*std.ArrayList(u8)) !void {
    for ([_]?std.Io.File{ process.child.stdout, process.child.stderr }, 0..) |maybe, index| {
        if (eof[index]) continue;
        const file = maybe orelse return error.MissingOutputPipe;
        var bytes: [4096]u8 = undefined;
        const count = try pipe.read(process.io, file, &bytes) orelse continue;
        if (count == 0) {
            eof[index] = true;
            continue;
        }
        if (output) |out| try out.accept(if (index == 0) .stdout else .stderr, bytes[0..count]);
        if (capture) |text| {
            if (count > 4096 - text.items.len) return error.VersionOutputLimit;
            try text.appendSlice(std.heap.page_allocator, bytes[0..count]);
        }
    }
}
