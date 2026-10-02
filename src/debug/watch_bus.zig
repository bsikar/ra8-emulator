//! The Zig core's bus with the debugger listening (RA8EMU-113). On
//! Unicorn, step_hook.zig's memory hook hands the stop machine every load
//! and store; the Zig core owns no hooks, so this sits between the core and
//! its bus and does the same: a store reaches the debug units the firmware
//! programs (FPB, DWT, ITM, DCB) through Driver.stored, and every access
//! reaches the watches and the DWT comparators through Machine.onAccess.
//!
//! It listens only while armed, which zig_drive does around one
//! instruction, and never to that instruction's own fetch.
const std = @import("std");
const bus = @import("../core/cpu/bus.zig");
const step_hook = @import("step_hook.zig");

pub const WatchBus = struct {
    inner: bus.Bus,
    driver: *step_hook.Driver,
    armed: bool = false,
    /// The instruction now running, whose fetch is not an access.
    fetch_from: u32 = 0,
    fetch_len: u32 = 0,

    pub fn view(self: *WatchBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    /// Listen to the instruction at `pc`, `size` bytes wide.
    pub fn arm(self: *WatchBus, pc: u32, size: u8) void {
        self.armed = true;
        self.fetch_from = pc;
        self.fetch_len = size;
    }

    pub fn disarm(self: *WatchBus) void {
        self.armed = false;
    }

    fn fetching(self: *const WatchBus, address: u32) bool {
        return address >= self.fetch_from and address -% self.fetch_from < self.fetch_len;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *WatchBus = @ptrCast(@alignCast(ctx));
        try self.inner.read(address, into);
        if (!self.armed or self.fetching(address)) return;
        self.driver.loaded(address);
        self.driver.machine.onAccess(address, width(into.len), .read, value(into));
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *WatchBus = @ptrCast(@alignCast(ctx));
        try self.inner.write(address, bytes);
        if (!self.armed) return;
        const moved = value(bytes);
        self.driver.stored(address, moved, width(bytes.len));
        self.driver.machine.onAccess(address, width(bytes.len), .write, moved);
    }
};

fn width(len: usize) u8 {
    return @intCast(@min(len, std.math.maxInt(u8)));
}

/// The low word an access moved, little-endian, as the Unicorn hook sees it.
fn value(bytes: []const u8) u32 {
    var word: [4]u8 = .{ 0, 0, 0, 0 };
    const len = @min(bytes.len, word.len);
    @memcpy(word[0..len], bytes[0..len]);
    return std.mem.readInt(u32, &word, .little);
}
