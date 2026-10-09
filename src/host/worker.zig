//! Host threads for model work that must not stall the run, such as the C6
//! DNS bridge's name lookups (RA8EMU-1020).
const std = @import("std");

pub const Thread = struct { thread: std.Thread };

const heap = std.heap.page_allocator;
const Call = struct { work: *const fn (*anyopaque) void, arg: *anyopaque };

/// Runs `work(arg)` on a new host thread.
pub fn spawn(work: *const fn (*anyopaque) void, arg: *anyopaque) !*Thread {
    const thread = try heap.create(Thread);
    errdefer heap.destroy(thread);
    thread.* = .{ .thread = try std.Thread.spawn(.{}, run, .{Call{ .work = work, .arg = arg }}) };
    return thread;
}

pub fn join(thread: *Thread) void {
    thread.thread.join();
    heap.destroy(thread);
}

pub fn detach(thread: *Thread) void {
    thread.thread.detach();
    heap.destroy(thread);
}

fn run(call: Call) void {
    call.work(call.arg);
}
