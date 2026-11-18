//! Win32 non-blocking 115200 8N1 reader for a J-Link CDC COM port.
const std = @import("std");

const win32 = @import("../../win32.zig");

const Dcb = extern struct {
    dcb_length: u32 = @sizeOf(Dcb),
    baud_rate: u32 = 115_200,
    flags: u32 = 0x0001 | 0x0010 | 0x1000,
    reserved: u16 = 0,
    xon_lim: u16 = 0,
    xoff_lim: u16 = 0,
    byte_size: u8 = 8,
    parity: u8 = 0,
    stop_bits: u8 = 0,
    xon_char: u8 = 0,
    xoff_char: u8 = 0,
    error_char: u8 = 0,
    eof_char: u8 = 0,
    evt_char: u8 = 0,
    reserved1: u16 = 0,
};

const Timeouts = extern struct {
    read_interval: u32 = 15,
    read_multiplier: u32 = 0,
    read_constant: u32 = 25,
    write_multiplier: u32 = 0,
    write_constant: u32 = 25,
};

extern "kernel32" fn GetCommState(file: win32.HANDLE, dcb: *Dcb) callconv(.winapi) win32.BOOL;
extern "kernel32" fn SetCommState(file: win32.HANDLE, dcb: *const Dcb) callconv(.winapi) win32.BOOL;
extern "kernel32" fn SetCommTimeouts(file: win32.HANDLE, to: *const Timeouts) callconv(.winapi) win32.BOOL;
extern "kernel32" fn PurgeComm(file: win32.HANDLE, flags: u32) callconv(.winapi) win32.BOOL;

pub fn allowedComName(port_name: []const u8) bool {
    if (port_name.len < 4 or port_name.len > 10) return false;
    if (!std.ascii.startsWithIgnoreCase(port_name, "COM")) return false;
    for (port_name[3..]) |ch| {
        if (!std.ascii.isDigit(ch)) return false;
    }
    const number = std.fmt.parseInt(u16, port_name[3..], 10) catch return false;
    // System/non-J-Link ports (including COM1, COM3, COM9) are refused unconditionally.
    return number != 0 and number != 1 and number != 3 and number != 9;
}

pub const Port = struct {
    handle: win32.HANDLE,

    pub fn open(port_name: []const u8) !Port {
        if (!allowedComName(port_name)) return error.ForbiddenSerialPort;
        var narrow: [24]u8 = undefined;
        const dev = try std.fmt.bufPrint(&narrow, "\\\\.\\{s}", .{port_name});
        var wide: [25:0]u16 = undefined;
        for (dev, 0..) |ch, i| {
            wide[i] = ch;
        }
        wide[dev.len] = 0;
        const handle = win32.CreateFileW(wide[0..dev.len :0], 0xC0000000, 0, null, 3, 0, null);
        if (handle == win32.invalid_handle) return error.SerialOpenFailed;
        errdefer std.os.windows.CloseHandle(handle);
        var dcb: Dcb = .{};
        if (!GetCommState(handle, &dcb).toBool()) return error.SerialConfigFailed;
        dcb.baud_rate = 115_200;
        dcb.byte_size = 8;
        dcb.parity = 0;
        dcb.stop_bits = 0;
        dcb.flags = 0x0001 | 0x0010 | 0x1000;
        if (!SetCommState(handle, &dcb).toBool()) return error.SerialConfigFailed;
        const timeouts: Timeouts = .{};
        if (!SetCommTimeouts(handle, &timeouts).toBool()) return error.SerialConfigFailed;
        _ = PurgeComm(handle, 0x000F);
        return .{ .handle = handle };
    }

    pub fn readBounded(
        self: *Port,
        io: std.Io,
        out: []u8,
        timeout_ms: u32,
        idle_ms: u32,
        cancel: ?*const std.atomic.Value(bool),
    ) !usize {
        const start = std.Io.Clock.awake.now(io).nanoseconds;
        const deadline = start + @as(i96, timeout_ms) * std.time.ns_per_ms;
        var last_rx = start;
        var total: usize = 0;
        while (total < out.len) {
            if (cancel) |flag| {
                if (flag.load(.acquire)) return error.Canceled;
            }
            const now = std.Io.Clock.awake.now(io).nanoseconds;
            if (now >= deadline) break;
            if (total > 0 and now - last_rx >= @as(i96, idle_ms) * std.time.ns_per_ms) break;
            var got: win32.DWORD = 0;
            const ask: win32.DWORD = @intCast(@min(out.len - total, 256));
            if (!win32.ReadFile(self.handle, out[total..].ptr, ask, &got, null).toBool()) {
                return error.SerialReadFailed;
            }
            if (got > 0) {
                total += got;
                last_rx = std.Io.Clock.awake.now(io).nanoseconds;
            }
        }
        return total;
    }

    pub fn close(self: *Port) void {
        if (self.handle != win32.invalid_handle) {
            std.os.windows.CloseHandle(self.handle);
            self.handle = win32.invalid_handle;
        }
    }
};
