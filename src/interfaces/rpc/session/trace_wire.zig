//! The RTOS trace wire messages (RA8EMU-832): what the `trace` topic
//! carries. Split out of the protocol vocabulary file so the file stays
//! small; rpc.zig re-exports these under the same names.
const proto = @import("rpc.zig");

/// One RTOS or exception event on the `trace` topic (RA8EMU-832): a
/// thread switch, the idle loop, or an ISR enter or leave, in order and
/// in board time.
pub const TraceEvent = struct {
    core: proto.Core,
    kind: proto.EventKind,
    /// Board time of the event, from the stream's virtual_ns.
    virtual_ns: u64,
    /// The control block of the switched-to thread; 0 for idle.
    thread: u32,
    /// The exception number entered or left; 0 for thread events.
    exception: u16,
    /// The thread's name from its TX_THREAD, empty when unreadable.
    name: []const u8,
    pub const max_len = .{ .name = 64 };
};
pub const Trace = struct {
    core: proto.Core,
    bytes: []const u8,
    pub const max_len = .{ .bytes = 4096 };
};
