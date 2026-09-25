//! The peripheral window and the blocks that live in it.
//!
//! The RA8D2 puts every Renesas peripheral in one window at 0x40000000, with a
//! Non-secure alias 0x10000000 above it. Firmware reaches that window long
//! before it reaches anything interesting, so the bus has to answer every
//! access: a modelled block answers for its own range, and everything else
//! falls through to a sparse register file that remembers what was written.
//!
//! The sparse fallback is not laziness, it is what lets unported firmware get
//! anywhere. A driver writes a control register and reads it back to check the
//! write took, so reads return the last value written. A driver then spins on a
//! status bit waiting for "ready", and a register nothing models would spin
//! forever, so an address read repeatedly with nothing written to it alternates
//! between zero and all-ones: a poll for either polarity of a single bit falls
//! through instead of hanging.
const std = @import("std");

/// The Secure peripheral window. These are silicon facts, not options.
pub const base: u32 = 0x4000_0000;
pub const size: u32 = 0x1000_0000;
/// The IDAU bit[28] Non-secure alias of the same window.
pub const ns_offset: u32 = 0x1000_0000;
pub const ns_base: u32 = base + ns_offset;

pub const Access = enum { read, write };

/// A modelled peripheral block: an absolute register range and the two
/// handlers that answer for it. A block owns its own state; the bus only
/// routes.
pub const Block = struct {
    name: []const u8,
    base: u32,
    size: u32,
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque, address: u32, width: u3) u32,
    writeFn: *const fn (context: *anyopaque, address: u32, width: u3, value: u32) void,

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

/// One sparse register: the last value written, and how many times it has been
/// read with nothing ever written to it.
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

pub const max_blocks = 64;

/// The peripheral bus: a small registry of modelled blocks plus the sparse
/// register file behind them.
pub const Bus = struct {
    blocks: [max_blocks]Block = undefined,
    count: usize = 0,
    cells: std.AutoHashMap(u32, Cell),
    counters: Counters = .{},

    pub fn init(allocator: std.mem.Allocator) Bus {
        return .{ .cells = std.AutoHashMap(u32, Cell).init(allocator) };
    }

    pub fn deinit(self: *Bus) void {
        self.cells.deinit();
    }

    /// Register a block. Ranges are disjoint by construction: registering an
    /// overlapping one is a programming error and is refused here rather than
    /// silently shadowing whichever block was added first.
    pub fn add(self: *Bus, block: Block) Error!void {
        if (self.count == max_blocks) return Error.TooManyBlocks;
        if (block.base < base or block.end() > @as(u64, base) + size) return Error.OutsideWindow;
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

    pub fn read(self: *Bus, address: u32, width: u3) u32 {
        self.counters.reads += 1;
        const canonical = canonicalize(address);
        if (self.blockFor(canonical)) |block| {
            self.counters.modelled += 1;
            return block.readFn(block.context, canonical, width);
        }
        const entry = self.cells.getOrPut(canonical) catch return 0;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const cell = entry.value_ptr;
        if (cell.written) return mask(cell.value, width);
        cell.reads += 1;
        // Alternate so a ready-bit poll of either polarity completes.
        return if (cell.reads % 2 == 0) mask(0xFFFF_FFFF, width) else 0;
    }

    pub fn write(self: *Bus, address: u32, width: u3, value: u32) void {
        self.counters.writes += 1;
        const canonical = canonicalize(address);
        if (self.blockFor(canonical)) |block| {
            self.counters.modelled += 1;
            block.writeFn(block.context, canonical, width, value);
            return;
        }
        const entry = self.cells.getOrPut(canonical) catch return;
        if (!entry.found_existing) entry.value_ptr.* = .{};
        entry.value_ptr.value = mask(value, width);
        entry.value_ptr.written = true;
    }

    /// How many distinct peripheral addresses the firmware has touched that
    /// nothing models. The porting worklist, in one number.
    pub fn unmodelledAddresses(self: *const Bus) usize {
        return self.cells.count();
    }
};

/// Fold the Non-secure alias onto the Secure address. One model answers both
/// windows, the way one block of silicon does.
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

const TestBlock = struct {
    hits: u32 = 0,
    last: u32 = 0,

    fn read(context: *anyopaque, address: u32, width: u3) u32 {
        _ = width;
        const self: *TestBlock = @ptrCast(@alignCast(context));
        self.hits += 1;
        return address;
    }

    fn write(context: *anyopaque, address: u32, width: u3, value: u32) void {
        _ = address;
        _ = width;
        const self: *TestBlock = @ptrCast(@alignCast(context));
        self.last = value;
    }

    fn descriptor(self: *TestBlock, at: u32, span: u32) Block {
        return .{
            .name = "test",
            .base = at,
            .size = span,
            .context = self,
            .readFn = read,
            .writeFn = write,
        };
    }
};

test "an unwritten register alternates so a ready-bit poll completes" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const status = base + 0x1234;
    try std.testing.expectEqual(@as(u32, 0), bus.read(status, 4));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), bus.read(status, 4));
    try std.testing.expectEqual(@as(u32, 0), bus.read(status, 4));
}

test "a written register reads back, masked to the access width" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    const control = base + 0x2000;
    bus.write(control, 4, 0xDEAD_BEEF);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), bus.read(control, 4));
    try std.testing.expectEqual(@as(u32, 0xEF), bus.read(control, 1));
    bus.write(control, 2, 0xFFFF_1234);
    try std.testing.expectEqual(@as(u32, 0x1234), bus.read(control, 4));
}

test "the Non-secure alias and the Secure window are one model" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    bus.write(base + 0x40, 4, 0xA5A5_0001);
    try std.testing.expectEqual(@as(u32, 0xA5A5_0001), bus.read(ns_base + 0x40, 4));
    try std.testing.expectEqual(@as(u32, 1), bus.unmodelledAddresses());
}

test "a registered block answers for its own range and nothing else" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var model = TestBlock{};
    try bus.add(model.descriptor(base + 0x8000, 0x1000));

    try std.testing.expectEqual(base + 0x8010, bus.read(base + 0x8010, 4));
    try std.testing.expectEqual(@as(u32, 1), model.hits);
    bus.write(ns_base + 0x8010, 4, 0x55);
    try std.testing.expectEqual(@as(u32, 0x55), model.last);

    _ = bus.read(base + 0x9000, 4);
    try std.testing.expectEqual(@as(u32, 1), model.hits);
    try std.testing.expectEqual(@as(u32, 2), bus.counters.modelled);
}

test "blocks are disjoint and inside the window" {
    var bus = Bus.init(std.testing.allocator);
    defer bus.deinit();
    var first = TestBlock{};
    var second = TestBlock{};
    try bus.add(first.descriptor(base + 0x8000, 0x1000));
    try std.testing.expectError(Error.OverlappingBlock, bus.add(second.descriptor(base + 0x8800, 0x1000)));
    try std.testing.expectError(Error.OutsideWindow, bus.add(second.descriptor(0x2000_0000, 0x1000)));
}
