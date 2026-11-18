//! The peripheral window and the blocks that live in it.
//!
//! By default the RA8D2 puts every Renesas peripheral in `0x4000_0000` with a
//! Non-secure alias `0x1000_0000` above it; a machine description may instead
//! install its own `MmioWindow` list and `UnknownPolicy` on `Bus` so unmapped
//! gaps and unmodelled registers fault as the target specifies (RA8EMU-1343).
const snapshot = @import("ra8_snapshot");

const std = @import("std");

/// The default RA8 Secure peripheral window and Non-secure alias.
pub const base: u32 = 0x4000_0000;
pub const size: u32 = 0x1000_0000;
pub const ns_offset: u32 = 0x1000_0000;
pub const ns_base: u32 = base + ns_offset;

pub const Access = enum { read, write };
pub const Issuer = enum { cpu0, cpu1 };

pub const ResolvedMmio = struct {
    canonical: u32,
    nonsecure: bool,
};

/// Peripheral MMIO aperture, with an optional Non-secure alias window of the
/// same size that folds onto `base`.
pub const MmioWindow = struct {
    base: u32,
    size: u32,
    ns_alias: ?u32 = null,

    pub fn end(self: MmioWindow) u64 {
        return @as(u64, self.base) + self.size;
    }

    pub fn covers(self: MmioWindow, address: u32, len: usize) bool {
        const stop = @as(u64, address) + len;
        if (address >= self.base and stop <= self.end()) return true;
        const alias = self.ns_alias orelse return false;
        return address >= alias and stop <= @as(u64, alias) + self.size;
    }

    pub fn touches(self: MmioWindow, address: u32, len: usize) bool {
        if (len == 0) return false;
        const first: u64 = address;
        const stop = first + len;
        if (first < self.end() and stop > self.base) return true;
        const alias = self.ns_alias orelse return false;
        return first < @as(u64, alias) + self.size and stop > alias;
    }

    pub fn resolve(self: MmioWindow, address: u32) ?ResolvedMmio {
        if (address >= self.base and address < self.end()) {
            return .{ .canonical = address, .nonsecure = false };
        }
        const alias = self.ns_alias orelse return null;
        if (address >= alias and address < @as(u64, alias) + self.size) {
            return .{ .canonical = self.base + (address - alias), .nonsecure = true };
        }
        return null;
    }
};

pub const UnknownPolicy = enum {
    /// RA8 unmodelled-register shadow cell with alternating poll readback.
    shadow_alternating,
    /// Refuse unmodelled register accesses as unmapped (`BusFault`).
    fault,
};

pub const default_windows = [_]MmioWindow{
    .{ .base = base, .size = size, .ns_alias = ns_base },
};

pub const Port = struct {
    bus: *Bus,
    issuer: Issuer,

    pub fn read(self: *Port, address: u32, width: u3) u32 {
        self.bus.issuer = self.issuer;
        return self.bus.read(address, width);
    }

    pub fn write(self: *Port, address: u32, width: u3, value: u32) void {
        self.bus.issuer = self.issuer;
        self.bus.write(address, width, value);
    }
};

pub const Gate = struct {
    context: *anyopaque,
    stoppedFn: *const fn (context: *anyopaque, address: u32) bool,
    noteFn: *const fn (context: *anyopaque, address: u32, access: Access) void,

    fn drops(self: Gate, address: u32, access: Access) bool {
        if (!self.stoppedFn(self.context, address)) return false;
        self.noteFn(self.context, address, access);
        return true;
    }
};

pub const Block = struct {
    name: []const u8,
    base: u32,
    size: u32,
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, address: u32, width: u3) u32,
    writeFn: *const fn (context: *anyopaque, address: u32, width: u3, value: u32) void,
    repeatFn: ?*const fn (context: *anyopaque, address: u32, width: u3, times: u64) bool = null,
    peekFn: ?*const fn (context: *anyopaque, address: u32, width: u3) u32 = null,

    pub fn end(self: Block) u64 {
        return @as(u64, self.base) + self.size;
    }

    pub fn covers(self: Block, address: u32) bool {
        return address >= self.base and address < self.end();
    }
};

pub const Error = error{
    TooManyBlocks,
    OverlappingBlock,
    OutsideWindow,
};

const Cell = struct {
    value: u32 = 0,
    written: bool = false,
    reads: u32 = 0,
};

pub const Counters = struct {
    reads: u64 = 0,
    writes: u64 = 0,
    modelled: u64 = 0,
};

pub const max_blocks = 192;

pub const Bus = struct {
    blocks: [max_blocks]Block = undefined,
    count: usize = 0,
    cells: std.AutoHashMap(u32, Cell),
    counters: Counters = .{},
    windows: []const MmioWindow = &default_windows,
    unknown: UnknownPolicy = .shadow_alternating,
    gate: ?Gate = null,
    nonsecure: bool = false,
    issuer: Issuer = .cpu0,
    ports: [2]Port = undefined,

    pub fn init(allocator: std.mem.Allocator) Bus {
        return .{ .cells = std.AutoHashMap(u32, Cell).init(allocator) };
    }

    pub fn port(self: *Bus, issuer: Issuer) *Port {
        const slot = &self.ports[@backingInt(issuer)];
        slot.* = .{ .bus = self, .issuer = issuer };
        return slot;
    }

    pub fn deinit(self: *Bus) void {
        self.cells.deinit();
    }

    pub fn inWindow(self: *const Bus, address: u32, len: usize) bool {
        for (self.windows) |window| {
            if (window.covers(address, len)) return true;
        }
        return false;
    }

    pub fn touchesWindow(self: *const Bus, address: u32, len: usize) bool {
        for (self.windows) |window| {
            if (window.touches(address, len)) return true;
        }
        return false;
    }

    pub fn resolve(self: *const Bus, address: u32) ?ResolvedMmio {
        for (self.windows) |window| {
            if (window.resolve(address)) |hit| return hit;
        }
        return null;
    }

    fn canonicalFitsWindow(self: *const Bus, start: u32, stop: u64) bool {
        for (self.windows) |window| {
            if (start >= window.base and stop <= window.end()) return true;
        }
        return false;
    }

    pub fn saveSnapshot(self: *const Bus, writer: *std.Io.Writer) !void {
        const fields = snapshot.fields;
        const keys = try self.cells.allocator.alloc(u32, self.cells.count());
        defer self.cells.allocator.free(keys);
        var iter = self.cells.keyIterator();
        var index: usize = 0;
        while (iter.next()) |key| : (index += 1) {
            keys[index] = key.*;
        }
        std.mem.sort(u32, keys, {}, std.sort.asc(u32));
        try fields.write(writer, self.counters);
        try fields.write(writer, self.nonsecure);
        try fields.write(writer, self.issuer);
        try fields.write(writer, @as(u32, @intCast(keys.len)));
        for (keys) |key| {
            try fields.write(writer, key);
            try fields.write(writer, self.cells.get(key).?);
        }
    }

    pub fn loadSnapshot(self: *Bus, payload: []const u8) !void {
        const fields = snapshot.fields;
        var cursor: fields.Cursor = .{ .bytes = payload };
        const counters = try fields.read(Counters, &cursor);
        const nonsecure = try fields.read(bool, &cursor);
        const issuer = try fields.read(Issuer, &cursor);
        const count = try fields.read(u32, &cursor);
        if (count > (payload.len - cursor.at) / 13) return error.Truncated;
        var cells = std.AutoHashMap(u32, Cell).init(self.cells.allocator);
        errdefer cells.deinit();
        var previous: ?u32 = null;
        for (0..count) |_| {
            const key = try fields.read(u32, &cursor);
            if (!self.canonicalFitsWindow(key, @as(u64, key) + 1)) return error.BadValue;
            if (previous) |last| if (key <= last) return error.BadValue;
            previous = key;
            try cells.put(key, try fields.read(Cell, &cursor));
        }
        if (!cursor.done()) return error.BadValue;
        self.cells.deinit();
        self.cells = cells;
        self.counters = counters;
        self.nonsecure = nonsecure;
        self.issuer = issuer;
    }

    pub fn add(self: *Bus, block: Block) Error!void {
        if (self.count == max_blocks) return Error.TooManyBlocks;
        if (!self.canonicalFitsWindow(block.base, block.end())) return Error.OutsideWindow;
        for (self.blocks[0..self.count]) |existing| {
            if (block.base < existing.end() and existing.base < block.end()) return Error.OverlappingBlock;
        }
        self.blocks[self.count] = block;
        self.count += 1;
    }

    pub fn blockFor(self: *Bus, address: u32) ?*Block {
        for (self.blocks[0..self.count]) |*block| {
            if (block.covers(address)) return block;
        }
        return null;
    }

    pub fn tryRead(self: *Bus, address: u32, width: u3) ?u32 {
        const hit = self.resolve(address) orelse return null;
        self.counters.reads += 1;
        self.nonsecure = hit.nonsecure;
        if (self.gate) |gate| {
            if (gate.drops(hit.canonical, .read)) return 0;
        }
        if (self.blockFor(hit.canonical)) |block| {
            self.counters.modelled += 1;
            return block.readFn(block.context, hit.canonical, width);
        }
        if (self.unknown == .fault) return null;
        const entry = self.cells.getOrPut(hit.canonical) catch return 0;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const cell = entry.value_ptr;
        if (cell.written) return mask(cell.value, width);
        cell.reads += 1;
        return if (cell.reads % 2 == 0) mask(0xFFFF_FFFF, width) else 0;
    }

    pub fn read(self: *Bus, address: u32, width: u3) u32 {
        return self.tryRead(address, width) orelse 0;
    }

    pub fn repeat(self: *Bus, address: u32, width: u3, times: u64) bool {
        const hit = self.resolve(address) orelse return false;
        if (self.gate) |gate| if (gate.stoppedFn(gate.context, hit.canonical)) return false;
        const block = self.blockFor(hit.canonical) orelse return false;
        const answer = block.repeatFn orelse return false;
        self.nonsecure = hit.nonsecure;
        if (!answer(block.context, hit.canonical, width, times)) return false;
        self.counters.reads += times;
        self.counters.modelled += times;
        return true;
    }

    pub fn peek(self: *Bus, address: u32, width: u3) ?u32 {
        const hit = self.resolve(address) orelse return null;
        if (self.gate) |gate| if (gate.stoppedFn(gate.context, hit.canonical)) return 0;
        if (self.blockFor(hit.canonical)) |block| {
            const look = block.peekFn orelse return null;
            return look(block.context, hit.canonical, width);
        }
        if (self.unknown == .fault) return null;
        const cell = self.cells.get(hit.canonical) orelse return null;
        return if (cell.written) mask(cell.value, width) else null;
    }

    pub fn tryWrite(self: *Bus, address: u32, width: u3, value: u32) bool {
        const hit = self.resolve(address) orelse return false;
        self.counters.writes += 1;
        self.nonsecure = hit.nonsecure;
        if (self.gate) |gate| {
            if (gate.drops(hit.canonical, .write)) return true;
        }
        if (self.blockFor(hit.canonical)) |block| {
            self.counters.modelled += 1;
            block.writeFn(block.context, hit.canonical, width, value);
            return true;
        }
        if (self.unknown == .fault) return false;
        const entry = self.cells.getOrPut(hit.canonical) catch return true;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.value = mask(value, width);
        entry.value_ptr.written = true;
        return true;
    }

    pub fn write(self: *Bus, address: u32, width: u3, value: u32) void {
        _ = self.tryWrite(address, width, value);
    }

    pub fn unmodelledAddresses(self: *const Bus) usize {
        return self.cells.count();
    }
};

pub fn canonicalize(address: u32) u32 {
    if (address >= ns_base and address < ns_base +% size) return address - ns_offset;
    return address;
}

fn mask(value: u32, width: u3) u32 {
    return switch (width) {
        1 => value & 0xFF,
        2 => value & 0xFFFF,
        else => value,
    };
}
