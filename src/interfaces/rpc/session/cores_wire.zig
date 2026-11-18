//! Wire types for `Method.list_cores` (RA8EMU-1342): the cores the machine
//! carries, slot by slot, with each core's ISA capabilities and whether the
//! session currently has that core attached.
const std = @import("std");

pub const flags = struct {
    pub const v8_1m: u8 = 1 << 0;
    pub const mve: u8 = 1 << 1;
    pub const lob: u8 = 1 << 2;
    pub const security: u8 = 1 << 3;
};

pub const name_cap: usize = 16;

pub const CoreItem = struct {
    slot: u8,
    attached: u8,
    cpuid: u32,
    flags: u8,
    fpu: u8,
    systicks: u8,
    name_len: u8,
    name: [name_cap]u8 = @splat(0),

    pub fn nameSlice(self: *const CoreItem) []const u8 {
        return self.name[0..@min(self.name_len, name_cap)];
    }
};

pub const item_bytes: usize = 1 + 1 + 4 + 1 + 1 + 1 + 1 + name_cap;
pub const max_items: usize = 2;

pub fn put(bytes: []u8, index: usize, item: CoreItem) void {
    const at = bytes[index * item_bytes ..][0..item_bytes];
    at[0] = item.slot;
    at[1] = item.attached;
    std.mem.writeInt(u32, at[2..6], item.cpuid, .little);
    at[6] = item.flags;
    at[7] = item.fpu;
    at[8] = item.systicks;
    const len: u8 = @intCast(@min(item.name_len, name_cap));
    at[9] = len;
    @memset(at[10 .. 10 + name_cap], 0);
    @memcpy(at[10..][0..len], item.name[0..len]);
}

pub fn count(bytes: []const u8) usize {
    return bytes.len / item_bytes;
}

pub fn get(bytes: []const u8, index: usize) CoreItem {
    const at = bytes[index * item_bytes ..][0..item_bytes];
    var out: CoreItem = .{
        .slot = at[0],
        .attached = at[1],
        .cpuid = std.mem.readInt(u32, at[2..6], .little),
        .flags = at[6],
        .fpu = at[7],
        .systicks = at[8],
        .name_len = @min(at[9], @as(u8, name_cap)),
    };
    @memcpy(&out.name, at[10 .. 10 + name_cap]);
    return out;
}

pub const CoreList = struct {
    machine: []const u8,
    count: u8,
    bytes: []const u8,
    pub const max_len = .{ .machine = 64, .bytes = max_items * item_bytes };
};
