//! The memory the Zig core fetches, loads and stores through.
//!
//! The core owns no memory. It reaches whatever the run hands it through this
//! one interface: the board's RAM and peripheral bus in a real run, a flat
//! array in a test.
const touched_api = @import("memory/touched.zig");

const std = @import("std");

const bus_fault = @import("../../periph/bus_fault.zig");
const code_lines = @import("code_lines.zig");
const Gate = @import("data_gate.zig").Gate;
const Initiator = @import("memory/initiator.zig").Initiator;
const memmap = @import("../memmap.zig");
const observer = @import("memory/observer.zig");
const Peer = @import("exclusive_peer.zig").Peer;

/// SecurityViolation: a Non-secure access the data gate refused (RA8EMU-274).
pub const Error = error{ Unmapped, SecurityViolation };

/// Fixed host-backed flash and SRAM ranges derived from the machine's
/// `MemoryMap` (RA8EMU-319, RA8EMU-1343).
pub const DirectMemory = struct {
    touched: ?*touched_api.Tracker = null,
    flash: ?[]u8 = null,
    flash_base: u32 = memmap.mram_base,
    flash_size: u32 = memmap.mram_end - memmap.mram_base,
    ns_flash_base: ?u32 = memmap.ns_mram_base,
    flash_writable: bool = true,
    sram: ?[]u8 = null,
    sram_base: u32 = memmap.sram_base,
    sram_size: u32 = memmap.sram_end - memmap.sram_base,
    ns_sram_base: ?u32 = memmap.ns_sram_base,
    sram_writable: bool = true,
    enabled: bool = false,
    /// The MPU check's armed flag. While it is set every access goes through
    /// the vtable, so the board bus can ask the MPU (RA8EMU-710).
    checking: ?*const bool = null,
    /// The trail hook the core's fast writes feed (H2); null records nothing.
    observer: ?*const observer.Observer = null,
    /// The initiator the core's own stores carry into the trail.
    initiator: Initiator = .none,
    /// The machine's block fanout, which a fast write invalidates.
    lines: ?*const code_lines.Fanout = null,

    const Located = struct { base: u32, offset: usize, data: []u8, writable: bool };

    inline fn locate(self: *const DirectMemory, address: u32, len: usize) ?Located {
        if (self.checking) |armed| if (armed.*) return null;
        if (locatePair(
            self.flash,
            self.flash_base,
            self.flash_size,
            self.ns_flash_base,
            self.flash_writable,
            address,
            len,
        )) |hit| return hit;
        return locatePair(
            self.sram,
            self.sram_base,
            self.sram_size,
            self.ns_sram_base,
            self.sram_writable,
            address,
            len,
        );
    }

    inline fn span(self: *const DirectMemory, address: u32, len: usize) ?[]u8 {
        const hit = self.locate(address, len) orelse return null;
        return hit.data;
    }

    inline fn read(self: *const DirectMemory, address: u32, into: []u8) bool {
        const data = self.span(address, into.len) orelse return false;
        @memcpy(into, data);
        return true;
    }

    /// A fast-path write (H2); a read-only region falls back to the vtable so
    /// the refused store raises its BusFault with BFAR.
    inline fn write(self: *const DirectMemory, address: u32, bytes: []const u8) bool {
        const hit = self.locate(address, bytes.len) orelse return false;
        if (!hit.writable) return false;
        if (self.touched) |tracker| tracker.note(hit.base, hit.offset, bytes.len);
        if (self.observer) |o| o.bytes(
            .{
                .base = hit.base,
                .offset = hit.offset,
                .initiator = self.initiator,
                .pre = hit.data,
                .new = bytes,
            },
        );
        @memcpy(hit.data, bytes);
        if (self.lines) |fan| fan.notify(address, bytes.len);
        return true;
    }

    inline fn locatePair(
        backing: ?[]u8,
        base: u32,
        size: u32,
        alias_base: ?u32,
        writable: bool,
        address: u32,
        len: usize,
    ) ?Located {
        const bytes = backing orelse return null;
        if (inSpan(base, size, address, len)) |offset| {
            if (offset <= bytes.len and len <= bytes.len - offset) {
                return .{ .base = base, .offset = offset, .data = bytes[offset..][0..len], .writable = writable };
            }
        }
        const view = alias_base orelse return null;
        if (inSpan(view, size, address, len)) |offset| {
            if (offset <= bytes.len and len <= bytes.len - offset) {
                return .{ .base = base, .offset = offset, .data = bytes[offset..][0..len], .writable = writable };
            }
        }
        return null;
    }

    inline fn inSpan(base: u32, size: u32, address: u32, len: usize) ?usize {
        if (address < base) return null;
        if (@as(u64, address) + len > @as(u64, base) + size) return null;
        return address - base;
    }
};

pub const Bus = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    direct: ?*const DirectMemory = null,
    gate: ?*Gate = null,
    miss: ?*u32 = null,
    tally: ?*bus_fault.Tally = null,
    peer: ?Peer = null,
    lines: ?*code_lines.Fanout = null,
    register_state: ?RegisterState = null,

    pub const RegisterState = struct { ctx: *anyopaque, vtable: *const VTable };

    pub fn registers(self: Bus) Bus {
        const state = self.register_state orelse return self;
        return .{ .ctx = state.ctx, .vtable = state.vtable };
    }

    pub const VTable = struct {
        read: *const fn (ctx: *anyopaque, address: u32, into: []u8) Error!void,
        write: *const fn (ctx: *anyopaque, address: u32, bytes: []const u8) Error!void,
        latch: ?*const fn (ctx: *anyopaque, address: u32, bits: u32) Error!void = null,
        repeat: ?*const fn (ctx: *anyopaque, address: u32, len: usize, times: u64) bool = null,
        peek: ?*const fn (ctx: *anyopaque, address: u32, into: []u8) bool = null,
        allowsExec: ?*const fn (ctx: *anyopaque, address: u32, len: usize) bool = null,
        touchesPeriph: ?*const fn (ctx: *anyopaque, address: u32, len: usize) ?bool = null,
    };

    pub fn allowsExec(self: Bus, address: u32, len: usize) bool {
        const check = self.vtable.allowsExec orelse return true;
        return check(self.ctx, address, len);
    }

    pub fn touchesPeriph(self: Bus, address: u32, len: usize) ?bool {
        const check = self.vtable.touchesPeriph orelse return null;
        return check(self.ctx, address, len);
    }

    pub fn peek(self: Bus, address: u32, into: []u8) bool {
        if (self.gate) |gate| if (gate.refuses(address, into.len)) return false;
        const look = self.vtable.peek orelse return false;
        return look(self.ctx, address, into);
    }

    pub fn repeat(self: Bus, address: u32, len: usize, times: u64) bool {
        const answer = self.vtable.repeat orelse return false;
        return answer(self.ctx, address, len, times);
    }

    pub inline fn read(self: Bus, address: u32, into: []u8) Error!void {
        if (self.gate) |gate| if (gate.refuses(address, into.len)) return error.SecurityViolation;
        if (into.len != 0) if (self.direct) |memory| {
            if (memory.enabled and memory.read(address, into)) return;
        };
        return self.vtable.read(self.ctx, address, into) catch |err| self.missed(err, address);
    }

    pub inline fn write(self: Bus, address: u32, bytes: []const u8) Error!void {
        if (self.gate) |gate| if (gate.refuses(address, bytes.len)) return error.SecurityViolation;
        if (self.peer) |other| other.stored(address, bytes.len);
        if (bytes.len != 0) {
            if (self.direct) |memory| {
                if (memory.enabled and memory.write(address, bytes)) return;
            }
            if (self.lines) |fan| fan.notify(address, bytes.len);
        }
        return self.vtable.write(self.ctx, address, bytes) catch |err| self.missed(err, address);
    }

    fn missed(self: Bus, err: Error, address: u32) Error {
        if (self.miss) |at| at.* = address;
        return err;
    }

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

    pub fn fetchHalf(self: Bus, address: u32) Error!u16 {
        if (!self.allowsExec(address, 2)) return Error.Unmapped;
        return self.readHalf(address);
    }

    pub fn readWord(self: Bus, address: u32) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn writeWord(self: Bus, address: u32, value: u32) Error!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        return self.write(address, &bytes);
    }
};
