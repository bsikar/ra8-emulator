//! Sweep only marked, unlocked, same-host ephemeral sessions. Every
//! deletion repeats authorization under the root gate, independent of the
//! earlier listing. There is no PID/heartbeat-based liveness shortcut.
const std = @import("std");
const Base = @import("base.zig").Base;
const name = @import("name.zig");
const catalog = @import("catalog.zig");
const remove = @import("remove.zig");

pub const Report = struct {
    removed: u64 = 0,
    protected: u64 = 0,
    other_hosts: u64 = 0,
    unmarked: u64 = 0,
    young: u64 = 0,
    failed: u64 = 0,
};

pub const Event = struct { entry: []const u8, result: anyerror!void };
pub const Observer = struct {
    context: *anyopaque,
    report: *const fn (*anyopaque, Event) void,
};

/// Also implements safe prune. Kept roots and kept markers are protected.
/// Observer entry strings live for the callback only.
pub fn run(base: *const Base, options: remove.Options, observer: ?Observer) !Report {
    if (options.allow_kept) return error.Kept;
    if (base.role != .runtime) try base.recover();
    var result: Report = .{};
    var pending: std.ArrayList(name.Buffer) = .empty;
    defer pending.deinit(base.allocator);
    var entries = try catalog.Iterator.init(base);
    while (try entries.next()) |entry| {
        switch (entry.status) {
            .stale, .creating => {
                var buffer: name.Buffer = @splat(0);
                @memcpy(buffer[0..entry.name.len], entry.name);
                try pending.append(base.allocator, buffer);
            },
            .other_host => result.other_hosts += 1,
            .unmarked, .foreign => result.unmarked += 1,
            else => result.protected += 1,
        }
    }
    for (pending.items) |*buffer| {
        const entry = std.mem.sliceTo(buffer, 0);
        const deleted = remove.entryRemove(base, entry, options);
        if (deleted) |_| {
            result.removed += 1;
        } else |err| switch (err) {
            error.Young => result.young += 1,
            error.Kept, error.Locked => result.protected += 1,
            error.OtherHost => result.other_hosts += 1,
            error.Unmarked, error.OutsideRoot => result.unmarked += 1,
            error.NotFound => {},
            else => result.failed += 1,
        }
        if (observer) |callback| callback.report(callback.context, .{ .entry = entry, .result = deleted });
    }
    return result;
}
