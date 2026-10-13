//! Fresh host measurements for application-owned budget decisions.
const std = @import("std");
const builtin = @import("builtin");
const budget = @import("budget.zig");

const MemoryStatus = extern struct {
    length: u32 = @sizeOf(MemoryStatus),
    load: u32 = 0,
    physical_total: u64 = 0,
    physical_available: u64 = 0,
    page_total: u64 = 0,
    page_available: u64 = 0,
    virtual_total: u64 = 0,
    virtual_available: u64 = 0,
    extended_available: u64 = 0,
};

extern "kernel32" fn GlobalMemoryStatusEx(status: *MemoryStatus) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn GetDiskFreeSpaceExW(path: [*:0]const u16, available: *u64, total: *u64, free: *u64) callconv(.winapi) std.os.windows.BOOL;

// Linux LP64 libc statvfs ABI. Only selected for a 64-bit Linux host.
// sysdeps/unix/sysv/linux/bits/statvfs.h: the final 24 bytes are reserved.
const LinuxVolume = extern struct {
    block_size: c_ulong,
    fragment_size: c_ulong,
    blocks: c_ulong,
    free: c_ulong,
    available: c_ulong,
    files: c_ulong,
    files_free: c_ulong,
    files_available: c_ulong,
    id: c_ulong,
    flags: c_ulong,
    name_max: c_ulong,
    spare: [6]u32,
};
extern "c" fn fstatvfs(fd: c_int, result: *LinuxVolume) c_int;

// Darwin's current 64-bit inode statfs ABI (bsd/sys/mount.h).
const DarwinVolume = extern struct {
    block_size: u32,
    io_size: i32,
    blocks: u64,
    free: u64,
    available: u64,
    files: u64,
    files_free: u64,
    id: [2]i32,
    owner: u32,
    kind: u32,
    flags: u32,
    subtype: u32,
    type_name: [16]u8,
    mount_name: [1024]u8,
    source_name: [1024]u8,
    extended_flags: u32,
    reserved: [7]u32,
};
extern "c" fn @"fstatfs$INODE64"(fd: c_int, result: *DarwinVolume) c_int;
extern "c" fn fstatfs(fd: c_int, result: *DarwinVolume) c_int;

pub fn physicalRam() error{MeasurementUnavailable}!u64 {
    if (builtin.os.tag == .windows) {
        var status: MemoryStatus = .{};
        if (!GlobalMemoryStatusEx(&status).toBool() or status.physical_total == 0) return error.MeasurementUnavailable;
        return status.physical_total;
    }
    if (builtin.os.tag == .macos) {
        var result: u64 = 0;
        var len: usize = @sizeOf(u64);
        if (std.c.sysctlbyname("hw.memsize", &result, &len, null, 0) != 0 or len != @sizeOf(u64) or result == 0) return error.MeasurementUnavailable;
        return result;
    }
    if (builtin.os.tag == .linux) {
        // glibc/musl _SC_PHYS_PAGES and _SC_PAGESIZE from unistd.h.
        const pages = std.c.sysconf(85);
        const page_size = std.c.sysconf(30);
        if (pages <= 0 or page_size <= 0) return error.MeasurementUnavailable;
        return std.math.mul(u64, @intCast(pages), @intCast(page_size)) catch error.MeasurementUnavailable;
    }
    return error.MeasurementUnavailable;
}

pub fn ramBudget(override: ?u64) !u64 {
    if (override) |cap| return budget.ram(0, cap);
    return budget.ram(try physicalRam(), null);
}

pub const Volume = struct { total: u64, available: u64 };

/// path must be a resolved absolute owned directory. POSIX fstatvfs uses
/// its open handle, while Windows uses its resolved path.
pub fn volume(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Volume {
    if (builtin.os.tag == .windows) {
        var path: [std.fs.max_path_bytes]u8 = undefined;
        const len = try dir.realPath(io, &path);
        const wide = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, path[0..len]);
        defer allocator.free(wide);
        var available: u64 = 0;
        var total: u64 = 0;
        var free: u64 = 0;
        if (!GetDiskFreeSpaceExW(wide, &available, &total, &free).toBool()) return error.MeasurementUnavailable;
        return .{ .total = total, .available = available };
    }
    if (builtin.os.tag == .linux and @sizeOf(usize) == 8) {
        var result: LinuxVolume = undefined;
        if (fstatvfs(dir.handle, &result) != 0) return error.MeasurementUnavailable;
        const unit = if (result.fragment_size != 0) result.fragment_size else result.block_size;
        return .{
            .total = try std.math.mul(u64, result.blocks, unit),
            .available = try std.math.mul(u64, result.available, unit),
        };
    }
    if (builtin.os.tag == .macos) {
        var result: DarwinVolume = undefined;
        const status = if (builtin.cpu.arch == .aarch64) fstatfs(dir.handle, &result) else @"fstatfs$INODE64"(dir.handle, &result);
        if (status != 0) return error.MeasurementUnavailable;
        return .{
            .total = try std.math.mul(u64, result.blocks, result.block_size),
            .available = try std.math.mul(u64, result.available, result.block_size),
        };
    }
    return error.MeasurementUnavailable;
}
