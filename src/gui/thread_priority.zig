//! Gives a shown run's engine thread an even footing with the window
//! (RA8EMU-227). The window sleeps on vsync and only reads snapshots, so
//! the engine is the thread that must not be pushed back. Best effort per
//! host, never fatal:
//! - macOS: QoS user-interactive, the class the window's main thread runs
//!   at, so the scheduler never ranks the engine below the UI.
//! - Windows: THREAD_PRIORITY_ABOVE_NORMAL, which needs no privilege.
//! - Linux and the rest: left alone. An unprivileged thread may only lower
//!   its priority there, and lowering the window would cost its frames.
const std = @import("std");
const builtin = @import("builtin");

pub const Outcome = enum { raised, unchanged, refused };

/// The host's raise for the calling thread; true when it took.
pub const Raise = *const fn () bool;

/// The calling thread's raise through `call`, or unchanged without one.
pub fn raiseWith(call: ?Raise) Outcome {
    const raise = call orelse return .unchanged;
    return if (raise()) .raised else .refused;
}

/// Raises the calling thread the way this host allows.
pub fn raiseEngine() Outcome {
    return raiseWith(host());
}

/// This host's raise, or null where there is none to make.
pub fn host() ?Raise {
    return switch (builtin.os.tag) {
        .macos => &macos.raise,
        .windows => &windows.raise,
        else => null,
    };
}

const macos = struct {
    const qos_user_interactive: c_uint = 0x21;
    extern "c" fn pthread_set_qos_class_self_np(qos: c_uint, relative: c_int) c_int;

    fn raise() bool {
        return pthread_set_qos_class_self_np(qos_user_interactive, 0) == 0;
    }
};

const windows = struct {
    /// The documented convention on 32-bit x86, the C one everywhere else.
    const cc: std.builtin.CallingConvention = if (builtin.cpu.arch == .x86) .winapi else .c;
    const above_normal: c_int = 1;
    extern "kernel32" fn GetCurrentThread() callconv(cc) ?*anyopaque;
    extern "kernel32" fn SetThreadPriority(thread: ?*anyopaque, priority: c_int) callconv(cc) c_int;

    fn raise() bool {
        return SetThreadPriority(GetCurrentThread(), above_normal) != 0;
    }
};
