//! Bounded 115200 8N1 serial capture on a J-Link probe's CDC interface,
//! opened solely by resolving the probe's USB serial at use time. Arbitrary
//! caller-supplied port names are never accepted.
const builtin = @import("builtin");
const std = @import("std");

const linux = @import("serial/linux.zig");
const uart = @import("uart.zig");
const windows = @import("serial/windows.zig");

pub const Port = struct {
    inner: switch (builtin.os.tag) {
        .windows => windows.Port,
        .linux => linux.Port,
        else => void,
    },
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,

    pub fn name(self: *const Port) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn openBySerial(io: std.Io, serial: u64) !?Port {
        var out: Port = .{ .inner = undefined };
        const found = (try uart.find(io, serial, &out.name_buf)) orelse return null;
        out.name_len = found.len;
        switch (builtin.os.tag) {
            .windows => out.inner = try windows.Port.open(found),
            .linux => out.inner = try linux.Port.open(found),
            else => return error.Unsupported,
        }
        return out;
    }

    pub fn readBounded(
        self: *Port,
        io: std.Io,
        out: []u8,
        timeout_ms: u32,
        idle_ms: u32,
        cancel: ?*const std.atomic.Value(bool),
    ) !usize {
        return switch (builtin.os.tag) {
            .windows => self.inner.readBounded(io, out, timeout_ms, idle_ms, cancel),
            .linux => self.inner.readBounded(io, out, timeout_ms, idle_ms, cancel),
            else => error.Unsupported,
        };
    }

    pub fn close(self: *Port) void {
        switch (builtin.os.tag) {
            .windows => self.inner.close(),
            .linux => self.inner.close(),
            else => {},
        }
    }
};
