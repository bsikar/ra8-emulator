//! Bounded debugger labels owned by a session.
const std = @import("std");

const Core = @import("event/stream.zig").Core;

pub const max_name = 48;
pub const capacity = 64;

/// Frame-relative storage has a different identity from an absolute address.
pub const Storage = enum(u8) { address, frame_offset, register, register_offset };

pub const Scope = struct {
    /// Offset of the DWARF variable entry that owns this frame storage.
    entry: u32,
    storage: Storage,
    register: u8 = 0,
};

pub const Key = struct {
    core: Core,
    address: u32,
    frame: ?Scope = null,
};

pub const Entry = struct {
    key: Key,
    width: u8,
    len: u8,
    bytes: [max_name]u8,

    pub fn name(self: *const Entry) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const View = struct {
    map: *const Map,
    core: Core,

    pub fn nameAt(self: View, address: u32) ?[]const u8 {
        const entry = self.map.at(.{ .core = self.core, .address = address }) orelse return null;
        return entry.name();
    }
};

pub const Map = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,

    pub fn at(self: *const Map, key: Key) ?*const Entry {
        const index = self.indexOf(key) orelse return null;
        return &self.entries[index];
    }

    pub fn byName(self: *const Map, core: Core, frame: ?u32, name: []const u8) ?*const Entry {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.key.core != core or frameEntry(entry.key) != frame) continue;
            if (std.mem.eql(u8, entry.name(), name)) return entry;
        }
        return null;
    }

    pub fn set(self: *Map, key: Key, name: []const u8, width: u8) !void {
        const index = self.indexOf(key);
        if (name.len == 0) {
            if (index) |i| {
                self.len -= 1;
                self.entries[i] = self.entries[self.len];
            }
            return;
        }

        if (!validName(name)) return error.InvalidLabel;
        switch (width) {
            0, 1, 2, 4, 8 => {},
            else => return error.InvalidLabelWidth,
        }
        if (self.byName(key.core, frameEntry(key), name)) |existing| {
            if (!std.meta.eql(existing.key, key)) return error.DuplicateLabel;
        }
        var entry: Entry = .{ .key = key, .width = width, .len = @intCast(name.len), .bytes = @splat(0) };
        @memcpy(entry.bytes[0..name.len], name);
        if (index) |i| {
            self.entries[i] = entry;
        } else {
            if (self.len == capacity) return error.LabelMapFull;
            self.entries[self.len] = entry;
            self.len += 1;
        }
    }

    pub fn clearCore(self: *Map, core: Core) void {
        var kept: usize = 0;
        for (self.entries[0..self.len]) |entry| {
            if (entry.key.core == core) continue;
            self.entries[kept] = entry;
            kept += 1;
        }
        self.len = kept;
    }

    fn indexOf(self: *const Map, key: Key) ?usize {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (std.meta.eql(entry.key, key)) return i;
        }
        return null;
    }
};

fn frameEntry(key: Key) ?u32 {
    return if (key.frame) |frame| frame.entry else null;
}

fn validName(name: []const u8) bool {
    if (name.len > max_name) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    }
    return true;
}
