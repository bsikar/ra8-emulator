//! What names this machine and this process in a session's owner record.
//! The host name decides whether a sweep may trust a directory's lock at
//! all; the pid and the boot id are only ever shown.
const std = @import("std");
const builtin = @import("builtin");

pub const limits = struct {
    pub const host = 768;
    pub const boot = 64;
};

pub const unknown = "unknown";

/// ComputerNameDnsHostname.
const dns_hostname: c_int = 1;
extern "kernel32" fn GetComputerNameExW(kind: c_int, buffer: ?[*]u16, size: *u32) callconv(.winapi) std.os.windows.BOOL;

/// This host's name, with anything a one-line record cannot hold replaced.
pub fn hostName(buffer: *[limits.host]u8) []const u8 {
    const raw = rawHostName(buffer);
    if (raw.len == 0) return unknown;
    for (raw) |*byte| {
        if (byte.* <= ' ' or byte.* == 0x7f) byte.* = '_';
    }
    return raw;
}

fn rawHostName(buffer: *[limits.host]u8) []u8 {
    if (builtin.os.tag == .windows) {
        var wide: [256]u16 = undefined;
        var len: u32 = wide.len;
        if (!GetComputerNameExW(dns_hostname, &wide, &len).toBool()) return buffer[0..0];
        return buffer[0..std.unicode.wtf16LeToWtf8(buffer, wide[0..len])];
    }
    var raw: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const got = std.posix.gethostname(&raw) catch return buffer[0..0];
    @memcpy(buffer[0..got.len], got);
    return buffer[0..got.len];
}

pub fn processId() u64 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

/// The kernel's id for this boot where the host publishes one, else empty.
pub fn bootId(io: std.Io, buffer: *[limits.boot]u8) []const u8 {
    if (builtin.os.tag != .linux) return "";
    const text = std.Io.Dir.cwd().readFile(io, "/proc/sys/kernel/random/boot_id", buffer) catch return "";
    return std.mem.trim(u8, text, " \r\n");
}
