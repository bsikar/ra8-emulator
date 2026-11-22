//! The answer loop the serve front runs on one connected peer (RA8EMU-736).
const builtin = @import("builtin");
const std = @import("std");

const Listener = @import("ra8_rpc").host_listener.Listener;
const served = @import("ra8_rpc").session.server;
const Service = @import("ra8_rpc").artifacts.service.Service;
const sock_ready = @import("ra8_host").sock.ready;
const sock_unix = @import("ra8_host").sock.unix;
const Stdio = @import("ra8_rpc").stdio_transport.Stdio;
const win32 = @import("ra8_host").win32;
const Worker = @import("ra8_rpc").served_worker.Worker;

/// How long an idle server waits on its peer before checking again.
const idle_wait_ms = 20;
const active_wait_ms = 12;

pub const Buffers = struct {
    rx: []u8,
    tx: []u8,
    listener: ?*Listener = null,

    pub fn pump(self: Buffers, context: *served.Context) !void {
        if (self.listener) |listener| {
            if (listener.gdb.items.len > 0) {
                if (context.worker) |w| w.acquire();
                defer if (context.worker) |w| w.release();
                listener.pumpGdb();
            }
            try listener.answer(context, self.tx);
        }
    }
};

/// What the peer's descriptor is, which decides how a hang-up shows.
pub const Link = enum { pipe, socket, unix_socket };

/// Set from a signal handler; the loops end at their next idle check.
pub var stopping = std.atomic.Value(bool).init(false);

/// Answer the client on stdin and stdout until stdin closes.
pub fn answerStdio(io: std.Io, context: *served.Context, buffers: Buffers) !void {
    var stdio = Stdio.process();
    try answer(io, context, stdio.transport(), stdio.input, .pipe, buffers);
}

/// Answer frames on `wire` until the peer behind `fd` closes or a stop is asked.
pub fn answer(
    io: std.Io,
    context: *served.Context,
    wire: served.rpc_lib.Transport,
    fd: std.posix.fd_t,
    link: Link,
    buffers: Buffers,
) !void {
    var host = served.Host.init(wire, buffers.rx, context);
    defer host.deinit();
    while (true) {
        try buffers.pump(context);
        const polled = host.poll(buffers.tx) catch |err| {
            if (err == error.LinkDown and try closed(io, fd, link)) return;
            return err;
        };
        if (polled != .idle) continue;
        if (try shouldStop(io, fd, link, context.worker)) return;
    }
}

fn idleWaitMs(worker_opt: ?*const Worker) i32 {
    const w = worker_opt orelse return idle_wait_ms;
    return if (w.isActive()) active_wait_ms else idle_wait_ms;
}

fn shouldStop(io: std.Io, fd: std.posix.fd_t, link: Link, worker_opt: ?*const Worker) !bool {
    if (stopping.load(.acquire)) return true;
    return closedWait(io, fd, link, idleWaitMs(worker_opt));
}

pub fn closed(io: std.Io, fd: std.posix.fd_t, link: Link) !bool {
    return closedWait(io, fd, link, idle_wait_ms);
}

/// Wait briefly on `fd`; true once the peer hung up with nothing left to read.
/// A socket reports that as readable with zero bytes behind it, so the socket
/// is peeked. A pipe reports HUP: alone on Linux once it is drained, but with
/// readable beside it on Darwin whether or not bytes are left, so a pipe that
/// reads as both is asked what it still holds.
fn closedWait(io: std.Io, fd: std.posix.fd_t, link: Link, wait_ms: i32) !bool {
    if (on_windows and link == .pipe) return pipeClosed(fd, @intCast(wait_ms));
    const ready = if (link == .unix_socket)
        try sock_unix.wait(io, fd, wait_ms)
    else
        try sock_ready.wait(io, fd, wait_ms);
    if (!ready.readable) return ready.hung_up;
    if (link == .pipe) return ready.hung_up and pipeDrained(fd);
    return peerGone(io, fd, link == .unix_socket);
}

const on_windows = builtin.os.tag == .windows;

/// FIONREAD, the bytes a read would take now. Zig 0.17's std names the
/// request for Linux; Darwin's <sys/filio.h> gives _IOR('f', 127, int).
fn pipeDrained(pipe: std.posix.fd_t) bool {
    if (on_windows) return false;
    const request: c_int = if (builtin.os.tag.isDarwin()) 0x4004667f else std.posix.T.FIONREAD;
    var waiting: c_int = 0;
    if (std.c.ioctl(pipe, request, &waiting) != 0) return false;
    return waiting == 0;
}

/// Windows pipes have no wait; an empty pipe sleeps the wait instead.
fn pipeClosed(pipe: std.posix.fd_t, wait_ms: u32) bool {
    const waiting = win32.pipeWaiting(pipe) orelse return true;
    if (waiting == 0) win32.Sleep(wait_ms);
    return false;
}

/// Peek one byte: zero bytes means the peer closed its end.
fn peerGone(io: std.Io, fd: std.posix.fd_t, is_unix: bool) bool {
    var byte: [1]u8 = undefined;
    const got = if (is_unix) sock_unix.takeByte(io, fd, &byte, true) else sock_ready.takeByte(io, fd, &byte, true);
    return (got orelse return true) == 0;
}

/// Stdio remains open for a fresh greeting after importing a replacement.
pub fn answerStdioManaged(io: std.Io, service: *Service) !void {
    var stdio = Stdio.process();
    try answerManaged(io, service, stdio.transport(), stdio.input, .pipe);
}

pub fn answerManaged(
    io: std.Io,
    service: *Service,
    wire: served.rpc_lib.Transport,
    fd: std.posix.fd_t,
    link: Link,
) !void {
    while (true) {
        if (!try managedSession(io, service, wire, fd, link)) return;
        service.activate();
        // Socket peers reconnect after their commit reply; stdio starts a new handshake.
        if (link != .pipe) return;
    }
}

fn managedSession(
    io: std.Io,
    service: *Service,
    wire: served.rpc_lib.Transport,
    fd: std.posix.fd_t,
    link: Link,
) !bool {
    const source = service.active;
    var host = served.Host.init(wire, source.rx, &source.context);
    defer host.deinit();
    errdefer service.discardPending();
    while (true) {
        const polled = host.poll(source.tx) catch |err| {
            service.discardPending();
            if (err == error.LinkDown and try closed(io, fd, link)) return false;
            return err;
        };
        if (service.pending != null) return true;
        if (polled != .idle) continue;
        if (try shouldStop(io, fd, link, source.context.worker)) return false;
    }
}
