//! The native peer's commit window: one arbiter between COMMIT and expiry.
const std = @import("std");

pub const State = enum(u8) { waiting, committing, settled, expired };

pub const Window = struct {
    state: std.atomic.Value(State) = .init(.waiting),

    /// The peer may rename only after this returns true.
    pub fn claim(self: *Window) bool {
        return self.state.cmpxchgStrong(.waiting, .committing, .seq_cst, .seq_cst) == null;
    }

    /// The watchdog may end a peer that never saw COMMIT only after this
    /// returns true, and from then on no COMMIT is honored.
    pub fn expire(self: *Window) bool {
        return self.state.cmpxchgStrong(.waiting, .expired, .seq_cst, .seq_cst) == null;
    }

    /// The rename call has returned, whatever it reported.
    pub fn settle(self: *Window) void {
        self.state.store(.settled, .seq_cst);
    }

    pub fn settled(self: *const Window) bool {
        return self.state.load(.seq_cst) == .settled;
    }
};
