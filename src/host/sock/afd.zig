//! Native operations on std.Io.net's Windows AFD handles. The caller owns
//! the handle; every batch is canceled and drained before its buffers die.
const std = @import("std");
const windows = std.os.windows;

pub const limits = struct {
    /// Bound native buffering and give the caller a deadline check between
    /// chunks, even when AFD could buffer a much larger request at once.
    pub const send_bytes: usize = 64 * 1024;
};

pub const Error = error{ SystemResources, Timeout, ConnectionReset, BrokenPipe, Unexpected };

const Events = struct {
    const receive: u32 = 0x0001;
    const send: u32 = 0x0004;
    const disconnect: u32 = 0x0008;
    const abort: u32 = 0x0010;
    const local_close: u32 = 0x0020;
    const accept: u32 = 0x0080;
    const connect_fail: u32 = 0x0100;
    const closed = disconnect | abort | local_close | connect_fail;
};

// One-handle AFD poll ABI, as described by libuv include/uv/win.h:187-198.
// https://github.com/libuv/libuv/blob/v1.x/include/uv/win.h
// Copyright Joyent, Inc. and other Node contributors. All rights reserved.
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included
// in all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.
pub const PollHandle = extern struct { handle: windows.HANDLE, events: u32, status: windows.NTSTATUS };
pub const PollInfo = extern struct { timeout: i64, count: u32, exclusive: u32, handles: [1]PollHandle };
pub const Ready = struct { readable: bool = false, hung_up: bool = false };

pub fn wait(io: std.Io, handle: windows.HANDLE, ms: i32) Error!Ready {
    var info: PollInfo = .{
        .timeout = if (ms < 0) std.math.maxInt(i64) else -@as(i64, ms) * 10_000,
        .count = 1,
        .exclusive = 0,
        .handles = .{.{ .handle = handle, .events = Events.receive | Events.accept | Events.closed, .status = .SUCCESS }},
    };
    const timeout: std.Io.Timeout = if (ms < 0) .none else .{ .duration = .{ .raw = .fromMilliseconds(@as(i64, ms) + 500), .clock = .awake } };
    const result = try control(io, handle, windows.IOCTL.AFD.POLL, std.mem.asBytes(&info), std.mem.asBytes(&info), timeout);
    if (result.u.Status == .TIMEOUT) return .{};
    _ = try check(result);
    if (info.count == 0) return .{};
    if (info.count != 1 or info.handles[0].handle != handle) return error.Unexpected;
    _ = try check(.{ .u = .{ .Status = info.handles[0].status }, .Information = 0 });
    const got = info.handles[0].events;
    return .{ .readable = got & (Events.receive | Events.accept) != 0, .hung_up = got & Events.closed != 0 };
}

pub fn receive(io: std.Io, handle: windows.HANDLE, bytes: []u8, peek: bool, timeout: std.Io.Timeout) Error!usize {
    if (bytes.len == 0) return 0;
    const buffers = [_]windows.AFD.WSABUF(.@"var"){.{ .len = @intCast(@min(bytes.len, std.math.maxInt(u32))), .buf = bytes.ptr }};
    const info: windows.AFD.RECV_INFO = .{
        .BufferArray = &buffers,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{ .NORMAL = true, .PEEK = peek },
    };
    return check(try control(io, handle, windows.IOCTL.AFD.RECEIVE, std.mem.asBytes(&info), &.{}, timeout));
}

pub fn send(io: std.Io, handle: windows.HANDLE, bytes: []const u8, timeout: std.Io.Timeout) Error!usize {
    if (bytes.len == 0) return 0;
    const buffers = [_]windows.AFD.WSABUF(.@"const"){.{ .len = @intCast(@min(bytes.len, limits.send_bytes)), .buf = bytes.ptr }};
    const info: windows.AFD.SEND_INFO = .{
        .BufferArray = &buffers,
        .BufferCount = 1,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{},
    };
    return check(try control(io, handle, windows.IOCTL.AFD.SEND, std.mem.asBytes(&info), &.{}, timeout));
}

fn control(io: std.Io, handle: windows.HANDLE, code: windows.CTL_CODE, in: []const u8, out: []u8, timeout: std.Io.Timeout) Error!windows.IO_STATUS_BLOCK {
    var storage: [1]std.Io.Operation.Storage = undefined;
    var batch = std.Io.Batch.init(&storage);
    defer cancel(io, &batch);
    batch.addAt(0, .{ .device_io_control = .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = code,
        .in = in,
        .out = out,
    } });
    batch.awaitConcurrent(io, timeout) catch |err| return switch (err) {
        error.Timeout => error.Timeout,
        else => error.SystemResources,
    };
    const completed = batch.next() orelse return error.Unexpected;
    return completed.result.device_io_control;
}

fn cancel(io: std.Io, batch: *std.Io.Batch) void {
    // Zig 0.17's Windows batchCancel first enters an infinite alertable
    // wait, before issuing NtCancelIoFileEx. Wake that first wait even when
    // the pending request has no completion APC yet; cancel then drains it.
    if (batch.pending.head != .none) {
        const status = windows.ntdll.NtAlertThread(windows.GetCurrentThread());
        std.debug.assert(status == .SUCCESS);
    }
    batch.cancel(io);
}

fn check(result: windows.IO_STATUS_BLOCK) Error!usize {
    return switch (result.u.Status) {
        .SUCCESS => result.Information,
        .CONNECTION_RESET, .REMOTE_DISCONNECT => error.ConnectionReset,
        .PIPE_BROKEN, .LOCAL_DISCONNECT => error.BrokenPipe,
        .IO_TIMEOUT, .TIMEOUT => error.Timeout,
        .INSUFFICIENT_RESOURCES => error.SystemResources,
        else => error.Unexpected,
    };
}
