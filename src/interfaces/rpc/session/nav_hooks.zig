//! What the navigation and rewind requests need from the application that
//! the session cannot reach itself: the late-marker cache's storage, the
//! rewind frame last sent to this connection, and the frame pipeline's
//! byte accounting for the status request.
const session_mod = @import("ra8_session");

pub const Position = session_mod.history_position.Position;

/// The frame pipeline's byte accounting, as the application reads it.
pub const FrameStatus = struct {
    ram_bytes: u64 = 0,
    disk_bytes: u64 = 0,
    queue_bytes: u64 = 0,
    frames: u64 = 0,
};

pub const Status = struct {
    context: *anyopaque,
    readFn: *const fn (context: *anyopaque) FrameStatus,
};

pub const Hooks = struct {
    /// The late-marker cache's storage; null keeps arrivals in memory.
    markers: ?session_mod.history_late_marker.Storage = null,
    /// The rewind frame last sent to this connection.
    rewind_sent: ?Position = null,
    status: ?Status = null,
};
