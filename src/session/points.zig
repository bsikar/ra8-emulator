//! Breakpoint and watchpoint operations on Session (RA8EMU-765).
const std = @import("std");
const api = @import("api.zig");
const breakpoint = @import("breakpoint.zig");
const watch_table = @import("watch/table.zig");

const Session = api.Session;
const Core = api.Core;
const BreakId = api.BreakId;
const WatchId = api.WatchId;

pub const RemovedPoint = enum { breakpoint, watchpoint };

pub fn setBreakpoint(self: *Session, core: Core, point: breakpoint.Break) anyerror!BreakId {
    try self.select(core);
    const id = try self.live.machine.addBreak(point);
    self.publish(.{ .core = core, .kind = .breakpoint_set, .address = point.address });
    return id;
}

pub fn setWatchpoint(self: *Session, core: Core, point: watch_table.Watch) anyerror!WatchId {
    try self.select(core);
    const id = try self.live.machine.addWatch(point);
    self.publish(.{ .core = core, .kind = .watchpoint_set, .address = point.first });
    return id;
}

pub fn clearBreakpoint(self: *Session, core: Core, id: BreakId) anyerror!void {
    try self.select(core);
    try self.live.machine.breaks.remove(id);
    self.publish(.{ .core = core, .kind = .breakpoint_cleared });
}

pub fn clearWatchpoint(self: *Session, core: Core, id: WatchId) anyerror!void {
    try self.select(core);
    try self.live.machine.watches.remove(id);
    self.publish(.{ .core = core, .kind = .watchpoint_cleared });
}

pub fn removePoint(self: *Session, core: Core, id: u32) anyerror!RemovedPoint {
    try self.select(core);
    self.live.machine.breaks.remove(id) catch |err| {
        if (err != error.NoSuchBreak) return err;
        self.live.machine.watches.remove(id) catch return error.NoSuchBreak;
        self.publish(.{ .core = core, .kind = .watchpoint_cleared });
        return .watchpoint;
    };
    self.publish(.{ .core = core, .kind = .breakpoint_cleared });
    return .breakpoint;
}

pub fn breakpointExists(self: *Session, core: Core, id: BreakId) anyerror!bool {
    return (try self.machine(core)).breaks.get(id) != null;
}

pub fn watchKind(self: *Session, core: Core, id: WatchId) anyerror!?watch_table.Kind {
    const point = (try self.machine(core)).watches.get(id) orelse return null;
    return point.kind;
}

pub fn matchingWatch(self: *Session, address: u32, len: u32) ?watch_table.Slot {
    const cores = [_]Core{ .cpu0, .cpu1 };
    const count: usize = if (self.hasCore(.cpu1)) 2 else 1;
    for (cores[0..count]) |c| {
        const m = self.machine(c) catch continue;
        for (m.watches.entries()) |slot| {
            if (!slot.enabled or !slot.watch.kind.covers(.write)) continue;
            const end = address +| (@max(len, 1) -| 1);
            if (address <= slot.watch.last and end >= slot.watch.first) return slot;
        }
    }
    return null;
}

pub fn hasArmedWriteWatch(self: *Session) bool {
    const cores = [_]Core{ .cpu0, .cpu1 };
    const count: usize = if (self.hasCore(.cpu1)) 2 else 1;
    for (cores[0..count]) |c| {
        const m = self.machine(c) catch continue;
        for (m.watches.entries()) |slot| {
            if (slot.enabled and slot.watch.kind.covers(.write)) return true;
        }
    }
    return false;
}
