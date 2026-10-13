//! Requests to stop the process, shared by every front (D16): SIGINT,
//! SIGTERM, SIGHUP and SIGQUIT on POSIX, and the console control events on
//! Windows. A request only sets a flag. The run loop reads it at its next
//! boundary and ends as a normal stop, so its deferred cleanup still runs.
//!
//! Windows ends a process about five seconds after a console close, logoff
//! or shutdown reaches its handler, so that handler holds the event for up
//! to `close_wait_ms` while the application finishes and calls `finished`.
//! Best effort: a cleanup slower than that is cut off, and the next start's
//! sweep clears what it left.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32.zig");

pub const Reason = enum(u8) { none, interrupt, terminate, hangup, quit, console_break, console_close, logoff, shutdown };

/// How long a console close, logoff or shutdown is held for `finished`.
pub const close_wait_ms: u32 = 4000;
const poll_ms: u32 = 10;

/// The Windows console control events (wincon.h).
pub const console = struct {
    pub const c: u32 = 0;
    pub const @"break": u32 = 1;
    pub const close: u32 = 2;
    pub const logoff: u32 = 5;
    pub const shutdown: u32 = 6;
};

var reason: std.atomic.Value(Reason) = .init(.none);
var done: std.atomic.Value(bool) = .init(false);

/// Catch the stop requests from here on. Safe to call more than once.
pub fn install() error{InstallFailed}!void {
    if (builtin.os.tag == .windows) {
        if (!win32.SetConsoleCtrlHandler(onConsole, .TRUE).toBool()) return error.InstallFailed;
        return;
    }
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    for ([_]std.posix.SIG{ .INT, .TERM, .HUP, .QUIT }) |signal| std.posix.sigaction(signal, &action, null);
}

/// Release the installed handlers on Windows. POSIX callers should
/// install once at process startup and retain them until exit.
pub fn uninstall() void {
    if (builtin.os.tag == .windows) _ = win32.SetConsoleCtrlHandler(onConsole, .FALSE);
}

/// True once a stop was asked for.
pub fn requested() bool {
    return why() != .none;
}

/// The first request since the last `reset`.
pub fn why() Reason {
    return reason.load(.acquire);
}

/// Ask for a stop, as a signal would. The first reason is the one kept.
pub fn request(asked: Reason) void {
    _ = reason.cmpxchgStrong(.none, asked, .acq_rel, .acquire);
}

/// The application's cleanup is over: a held console close may return.
pub fn finished() void {
    done.store(true, .release);
}

/// Forget the request, for a front that serves again and for tests.
pub fn reset() void {
    reason.store(.none, .release);
    done.store(false, .release);
}

/// Wait for `finished`, at most `limit_ms`, sleeping through `pause`. True
/// when the cleanup finished in time.
pub fn awaitFinished(limit_ms: u32, pause: *const fn (ms: u32) void) bool {
    var waited: u32 = 0;
    while (!done.load(.acquire)) : (waited += poll_ms) {
        if (waited >= limit_ms) return false;
        pause(poll_ms);
    }
    return true;
}

/// What a console control event asks for; null for one that is not a stop.
pub fn consoleReason(event: u32) ?Reason {
    return switch (event) {
        console.c => .interrupt,
        console.@"break" => .console_break,
        console.close => .console_close,
        console.logoff => .logoff,
        console.shutdown => .shutdown,
        else => null,
    };
}

/// True for the events after which Windows ends the process whatever the
/// handler answers, which are the ones worth holding.
pub fn held(asked: Reason) bool {
    return switch (asked) {
        .console_close, .logoff, .shutdown => true,
        else => false,
    };
}

fn onSignal(signal: std.posix.SIG) callconv(.c) void {
    request(switch (signal) {
        .INT => .interrupt,
        .HUP => .hangup,
        .QUIT => .quit,
        else => .terminate,
    });
}

fn onConsole(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    return .fromBool(consoleEvent(event));
}

/// The same dispatch path used by the installed Windows OS handler.
/// Exposed so an owned runtime harness can exercise held cleanup events.
pub fn consoleEvent(event: u32) bool {
    const asked = consoleReason(event) orelse return false;
    request(asked);
    if (held(asked)) _ = awaitFinished(close_wait_ms, sleep);
    return true;
}

fn sleep(ms: u32) void {
    win32.Sleep(ms);
}
