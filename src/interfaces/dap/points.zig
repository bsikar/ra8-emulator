//! Wire ownership of source/instruction breakpoints. Session owns their state.
const std = @import("std");
const session = @import("ra8_session");
const p = @import("protocol.zig");
pub const Points = struct {
    entries: std.ArrayList(Entry) = .empty,
    const Entry = struct { source: []u8, core: session.api.Core, id: session.api.BreakId };

    pub fn isInstruction(self: *const Points, core: session.api.Core, id: session.api.BreakId) bool {
        for (self.entries.items) |entry| {
            if (entry.core == core and entry.id == id) return entry.source.len == 0;
        }
        return false;
    }

    pub fn deinit(self: *Points, allocator: std.mem.Allocator, live: ?*session.api.Session) void {
        for (self.entries.items) |entry| {
            if (live) |s| s.clearBreakpoint(entry.core, entry.id) catch {};
            allocator.free(entry.source);
        }
        self.entries.deinit(allocator);
    }

    pub fn replace(self: *Points, allocator: std.mem.Allocator, live: *session.api.Session, image: ?session.symbols.Image, args: p.Value, instructions: bool, out: *std.Io.Writer, lines_start_at_one: bool) !void {
        const key = if (instructions) "" else try p.text(p.get(p.get(args, "source"), "path"));
        const value = p.get(args, "breakpoints");
        const asked = if (value == .null) &.{} else try p.list(value);
        if (asked.len > session.breaks.table.limits.capacity) return error.TooManyBreakpoints;
        for (asked) |item| {
            if (item != .object) return error.InvalidArguments;
            if (!instructions) {
                const line = try p.number(p.get(item, "line"));
                if (lines_start_at_one and line == 0) return error.InvalidArguments;
            }
        }
        const core = live.currentCore();
        var at: usize = 0;
        while (at < self.entries.items.len) {
            const entry = self.entries.items[at];
            if (entry.core != core or !std.mem.eql(u8, entry.source, key)) {
                at += 1;
                continue;
            }
            live.clearBreakpoint(core, entry.id) catch |err| if (err != error.NoSuchBreak) return err;
            allocator.free(entry.source);
            _ = self.entries.orderedRemove(at);
        }
        try out.writeAll("{\"breakpoints\":[");
        for (asked, 0..) |item, index| {
            if (index > 0) try out.writeByte(',');
            if (p.get(item, "condition") != .null or p.get(item, "hitCondition") != .null or p.get(item, "logMessage") != .null) {
                try p.quote(out, .{ .verified = false, .message = "conditional and log breakpoints are unsupported" });
                continue;
            }
            const line = if (instructions) 0 else try p.number(p.get(item, "line"));
            const address = if (instructions) instruction(item) catch null else session.source.breakAt(image, .{ .file = key, .line = line +| @intFromBool(!lines_start_at_one) });
            try self.install(allocator, live, core, key, address, line, out);
        }
        try out.writeAll("]}");
    }

    fn install(self: *Points, allocator: std.mem.Allocator, live: *session.api.Session, core: session.api.Core, key: []const u8, address: ?u32, line: u32, out: *std.Io.Writer) !void {
        const at = address orelse return p.quote(out, .{ .verified = false, .line = line, .message = "no code at this location" });
        const owned = try allocator.dupe(u8, key);
        self.entries.ensureUnusedCapacity(allocator, 1) catch |err| {
            allocator.free(owned);
            return err;
        };
        const id = live.setBreakpoint(core, .{ .address = at }) catch |err| {
            allocator.free(owned);
            return p.quote(out, .{ .verified = false, .line = line, .message = @errorName(err) });
        };
        self.entries.appendAssumeCapacity(.{ .source = owned, .core = core, .id = id });
        try p.quote(out, .{ .id = id, .verified = true, .line = line });
    }

    fn instruction(item: p.Value) !u32 {
        const ref = try p.text(p.get(item, "instructionReference"));
        const base = try std.fmt.parseInt(u32, ref, 0);
        const offset = p.get(item, "offset");
        const delta: i64 = if (offset == .null) 0 else if (offset == .integer) offset.integer else return error.InvalidArguments;
        const at = try std.math.add(i64, base, delta);
        return std.math.cast(u32, at) orelse error.InvalidArguments;
    }
};
