//! The memory the Zig core fetches, loads and stores through.
//!
//! The core owns no memory. It reaches whatever the run hands it through this
//! one interface: the board's RAM and peripheral bus in a real run, a flat
//! array in a test. Unicorn keeps its own view of the same bytes, which is
//! what lets a lockstep run compare the two.
const std = @import("std");
const memmap = @import("../memmap.zig");
const Gate = @import("data_gate.zig").Gate;

/// SecurityViolation: a Non-secure access the data gate refused (RA8EMU-274).
pub const Error = error{ Unmapped, SecurityViolation };

/// Fixed host-backed ranges. Separate fields avoid a per-access region loop;
/// peripheral addresses and cross-range accesses continue through the vtable.
pub const DirectMemory = struct {
    flash: ?[]u8 = null,
    sram: ?[]u8 = null,
    enabled: bool = false,

    inline fn read(self: *const DirectMemory, address: u32, into: []u8) bool {
        const data = self.span(address, into.len) orelse return false;
        @memcpy(into, data);
        return true;
    }

    inline fn write(self: *const DirectMemory, address: u32, bytes: []const u8) bool {
        const data = self.span(address, bytes.len) orelse return false;
        @memcpy(data, bytes);
        return true;
    }

    inline fn span(self: *const DirectMemory, address: u32, len: usize) ?[]u8 {
        if (address >= memmap.mram_base and address < memmap.mram_end) {
            const offset = address - memmap.mram_base;
            if (len > memmap.mram_end - memmap.mram_base - offset) return null;
            const bytes = self.flash orelse return null;
            return bytes[offset..][0..len];
        }
        if (address >= memmap.sram_base and address < memmap.sram_end) {
            const offset = address - memmap.sram_base;
            if (len > memmap.sram_end - memmap.sram_base - offset) return null;
            const bytes = self.sram orelse return null;
            return bytes[offset..][0..len];
        }
        if (address >= memmap.ns_sram_base and address < memmap.ns_sram_end) {
            const offset = address - memmap.ns_sram_base;
            if (len > memmap.ns_sram_end - memmap.ns_sram_base - offset) return null;
            const bytes = self.sram orelse return null;
            return bytes[offset..][0..len];
        }
        return null;
    }
};

pub const Bus = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    direct: ?*const DirectMemory = null,
    /// Attribution on data accesses; null checks nothing (RA8EMU-274).
    gate: ?*Gate = null,

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, address: u32, into: []u8) Error!void,
        write: *const fn (ctx: *anyopaque, address: u32, bytes: []const u8) Error!void,
        /// Sets bits in a status word without a store; null reads and
        /// writes the word back instead.
        latch: ?*const fn (ctx: *anyopaque, address: u32, bits: u32) Error!void = null,
    };

    pub inline fn read(self: Bus, address: u32, into: []u8) Error!void {
        if (self.gate) |gate| if (gate.refuses(address, into.len)) return error.SecurityViolation;
        if (into.len != 0) if (self.direct) |memory| {
            if (memory.enabled and memory.read(address, into)) return;
        };
        return self.vtable.read(self.ctx, address, into);
    }

    pub inline fn write(self: Bus, address: u32, bytes: []const u8) Error!void {
        if (self.gate) |gate| if (gate.refuses(address, bytes.len)) return error.SecurityViolation;
        if (bytes.len != 0) if (self.direct) |memory| {
            if (memory.enabled and memory.write(address, bytes)) return;
        };
        return self.vtable.write(self.ctx, address, bytes);
    }

    /// Set `bits` in a status word the way the core raises a fault. This is
    /// not a store: a bus with a write-one-to-clear model behind it must not
    /// take the core's own latch for an acknowledge (RA8EMU-394).
    pub fn latch(self: Bus, address: u32, bits: u32) Error!void {
        if (self.vtable.latch) |set| return set(self.ctx, address, bits);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, try self.readWord(address) | bits, .little);
        return self.write(address, &bytes);
    }

    pub fn readHalf(self: Bus, address: u32) Error!u16 {
        var bytes: [2]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u16, &bytes, .little);
    }

    pub fn readWord(self: Bus, address: u32) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }
};
