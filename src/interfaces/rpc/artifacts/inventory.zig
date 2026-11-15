//! Stable metadata inventory for a synchronous export; payloads stream one file at a time.
const std = @import("std");

const bundle = @import("ra8_snapshot").bundle;
const history = @import("ra8_host").history;
const setup = @import("../served_setup.zig");
const wire = @import("wire.zig");

pub const Entry = struct {
    space: bundle.writer.Space,
    name: []const u8,
    size: u64,
    bytes: ?[]const u8 = null,
};

pub const Inventory = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    cost: u64 = 0,
    area: bundle.writer.Space = .log,

    pub fn deinit(self: *Inventory) void {
        for (self.entries.items) |entry| {
            self.gpa.free(entry.name);
        }
        self.entries.deinit(self.gpa);
    }

    pub fn gather(self: *Inventory, source: *setup.Served) !void {
        if (source.history) |bind| {
            const store = history.storage.Store.from(&bind.session);
            try store.vtable.list(store.context, .log, .{ .context = self, .visit = visit });
            self.area = .objects;
            try store.vtable.list(store.context, .objects, .{ .context = self, .visit = visit });
        } else if (source.ram_history) |ram| {
            try self.add(.log, "events-0", ram.log_bytes.items.len, ram.log_bytes.items);
            for (ram.objects.items) |entry| {
                try self.add(.objects, &entry.name, entry.bytes.len, entry.bytes);
            }
        } else return error.NoRecording;
        std.mem.sort(Entry, self.entries.items, {}, less);
    }

    fn visit(context: *anyopaque, name: []const u8, size: u64) anyerror!void {
        const self: *Inventory = @ptrCast(@alignCast(context));
        try self.add(self.area, name, size, null);
    }

    fn add(self: *Inventory, area: bundle.writer.Space, name: []const u8, size: u64, bytes: ?[]const u8) !void {
        if (self.entries.items.len >= 4092) return error.TooLarge;
        const extra = try entryCost(size);
        if (extra > wire.max_bundle - self.cost) return error.TooLarge;
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.entries.append(self.gpa, .{ .space = area, .name = owned, .size = size, .bytes = bytes });
        self.cost += extra;
    }

    fn less(_: void, a: Entry, b: Entry) bool {
        if (a.space != b.space) return a.space == .log;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }
};

pub fn entryCost(size: u64) !u64 {
    if (size > 1024 * 1024 * 1024) return error.TooLarge;
    return 512 + size + (512 - size % 512) % 512;
}

pub fn append(writer: *bundle.writer.Writer, source: *setup.Served, entry: Entry) !void {
    if (entry.bytes) |bytes| {
        var reader = std.Io.Reader.fixed(bytes);
        return writer.add(entry.space, entry.name, .{ .reader = &reader, .size = entry.size });
    }
    const store = history.storage.Store.from(&source.history.?.session);
    const byte = try store.vtable.open(store.context, if (entry.space == .log) .log else .objects, entry.name, .read);
    defer byte.vtable.close(byte.context);
    if (try byte.vtable.length(byte.context) != entry.size) return error.SourceChanged;
    const file = try history.storage.native(byte);
    var buffer: [65536]u8 = undefined;
    var reader = file.reader(source.io, &buffer);
    try writer.add(entry.space, entry.name, .{ .reader = &reader.interface, .size = entry.size });
}
