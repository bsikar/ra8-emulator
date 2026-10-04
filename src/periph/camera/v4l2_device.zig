//! An open V4L2 node on the host (RA8EMU-506): the file descriptor behind
//! the negotiation's ioctl seam, plus read() capture and release.
//!
//! Only Linux has V4L2. On other hosts `open` refuses with Unsupported and
//! nothing touches the system; the macOS and Windows webcams have their
//! own tickets (RA8EMU-502, RA8EMU-501).
const std = @import("std");
const builtin = @import("builtin");
const negotiate = @import("v4l2_negotiate.zig");
const stream = @import("v4l2_stream.zig");

/// True on hosts where a V4L2 device can be opened.
pub const supported = builtin.os.tag == .linux;

/// The errno an ioctl reports on a host without V4L2 (ENOSYS).
const no_system_call: u16 = 38;

pub const OpenError = error{ Unsupported, OpenFailed };
pub const ReadError = error{ ReadFailed, ShortFrame };

pub const Fd = struct {
    fd: std.posix.fd_t,

    /// Opens `path` for capture. Callers pass the consent gate first.
    pub fn open(path: []const u8) OpenError!Fd {
        if (comptime !supported) return error.Unsupported;
        const flags: std.posix.O = .{ .ACCMODE = .RDWR, .CLOEXEC = true };
        const fd = std.posix.open(path, flags, 0) catch return error.OpenFailed;
        return .{ .fd = fd };
    }

    /// The ioctl seam the negotiation drives.
    pub fn device(self: *Fd) negotiate.Device {
        return .{ .ctx = self, .ioctlFn = ioctl };
    }

    fn ioctl(ctx: *anyopaque, request: u32, arg: *anyopaque) u16 {
        if (comptime !supported) return no_system_call;
        const self: *Fd = @ptrCast(@alignCast(ctx));
        const rc = std.os.linux.ioctl(self.fd, request, @intFromPtr(arg));
        return @intFromEnum(std.os.linux.E.init(rc));
    }

    /// Reads one whole frame of `out.len` bytes with read() I/O.
    pub fn readFrame(self: *Fd, out: []u8) ReadError!void {
        const got = std.posix.read(self.fd, out) catch return error.ReadFailed;
        if (got != out.len) return error.ShortFrame;
    }

    /// The mapping seam a memory-mapped stream maps driver buffers with.
    pub fn mapper(self: *Fd) stream.Mapper {
        return .{ .ctx = self, .mapFn = map, .unmapFn = unmap };
    }

    fn map(ctx: *anyopaque, offset: u32, length: u32) ?[]u8 {
        if (comptime !supported) return null;
        const self: *Fd = @ptrCast(@alignCast(ctx));
        const prot = std.posix.PROT.READ | std.posix.PROT.WRITE;
        return std.posix.mmap(null, length, prot, .{ .TYPE = .SHARED }, self.fd, offset) catch null;
    }

    fn unmap(ctx: *anyopaque, memory: []u8) void {
        _ = ctx;
        if (comptime !supported) return;
        std.posix.munmap(@alignCast(memory));
    }

    /// Releases the device.
    pub fn close(self: *Fd) void {
        std.posix.close(self.fd);
        self.fd = -1;
    }
};
