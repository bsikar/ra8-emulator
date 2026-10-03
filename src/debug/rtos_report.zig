//! What `--trace-rtos` and `--cpu-load` print as a run ends (RA8EMU-267).
//!
//! Both read one tracer: the trace it kept, and the load its trace fed as
//! every event went by (src/debug/rtos_load.zig). The load table gives each
//! owner its ticks and its share of the core's run in tenths of a percent,
//! split by largest remainder so a core's shares add up to exactly 100.0%.
//!
//! Load is counted in instructions retired on the core: one by one on
//! Unicorn, and on the Zig core in the timebase's elapsed count, which
//! moves a chunk at a time.
const std = @import("std");
const rtos_hook = @import("rtos_hook.zig");
const rtos_load = @import("rtos_load.zig");
const names = @import("rtos_names.zig");
const isr = @import("rtos_isr.zig");
const rtos_file = @import("rtos_file.zig");

pub const limits = struct {
    /// A whole core's run, in the tenths of a percent shares are counted in.
    pub const whole: u64 = 1000;
    /// Rows a table can have: every kept owner, then `other`.
    pub const rows: usize = rtos_load.limits.slots + 1;
};

/// The trace when `--trace-rtos` asked, then the load when `--cpu-load` did.
pub fn all(out: anytype, options: anytype, tracer: ?*const rtos_hook.Tracer, memory: anytype) !void {
    if (options.trace_rtos) try rtos_hook.print(out, tracer, memory);
    if (options.cpu_load) try load(out, tracer, memory);
    const one = tracer orelse return;
    if (outPath(options)) |path| try rtos_file.save(path, one.core, &one.trace);
}

/// `--trace-rtos-out`, when the options carry it and it was given.
fn outPath(options: anytype) ?[]const u8 {
    const T = @TypeOf(options);
    const Fields = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
    if (!@hasField(Fields, "trace_rtos_out")) return null;
    return options.trace_rtos_out;
}

/// One core's load table: the tracer's core, charged up to its clock now.
pub fn load(out: anytype, tracer: ?*const rtos_hook.Tracer, memory: anytype) !void {
    const one = tracer orelse return;
    var copy = one.trace.load;
    copy.finish(one.loadClock());
    const total = copy.total(one.core);
    try out.print("  cpu load cpu{d} : {d} instruction(s)\n", .{ one.core, total });
    if (total == 0) return;
    const slots = copy.rows(one.core);
    var ticks: [limits.rows]u64 = undefined;
    for (slots, 0..) |slot, index| ticks[index] = slot.ticks;
    ticks[slots.len] = copy.cores[one.core].other;
    var shares: [limits.rows]u64 = undefined;
    split(ticks[0 .. slots.len + 1], total, &shares);
    for (slots, 0..) |slot, index| {
        try share(out, shares[index], slot.ticks);
        try owner(out, slot.owner, memory);
    }
    if (ticks[slots.len] > 0) {
        try share(out, shares[slots.len], ticks[slots.len]);
        try out.print("other\n", .{});
    }
}

/// Shares of `total` in tenths of a percent, floored, with what flooring
/// lost handed one tenth at a time to the largest remainders, so they add
/// up to exactly `limits.whole`. `ticks` must add up to `total`.
pub fn split(ticks: []const u64, total: u64, into: []u64) void {
    var left: [limits.rows]u64 = undefined;
    var given: u64 = 0;
    for (ticks, 0..) |count, index| {
        const scaled = @as(u128, count) * limits.whole;
        into[index] = @intCast(scaled / total);
        left[index] = @intCast(scaled % total);
        given += into[index];
    }
    while (given < limits.whole) : (given += 1) {
        var best: usize = 0;
        for (ticks, 0..) |_, index| {
            if (left[index] > left[best]) best = index;
        }
        if (left[best] == 0) return;
        into[best] += 1;
        left[best] = 0;
    }
}

fn share(out: anytype, tenths: u64, ticks: u64) !void {
    try out.print("                  {d: >3}.{d}% {d: >10}  ", .{ tenths / 10, tenths % 10, ticks });
}

fn owner(out: anytype, who: rtos_load.Owner, memory: anytype) !void {
    switch (who.kind) {
        .before => try out.print("before the first switch\n", .{}),
        .idle => try out.print("idle\n", .{}),
        .thread => {
            try out.print("0x{X:0>8}", .{who.id});
            var buffer: [names.longest]u8 = undefined;
            if (names.name(memory, who.id, &buffer)) |text| try out.print(" {s}", .{text});
            try out.print("\n", .{});
        },
        .exception => {
            const number: u16 = @intCast(who.id);
            if (isr.label(number)) |text| return out.print("{s}\n", .{text});
            if (number >= 16) return out.print("IRQ{d}\n", .{number - 16});
            try out.print("exception {d}\n", .{number});
        },
    }
}
