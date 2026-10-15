//! The native peer's commit window: one arbiter between the peer's own
//! progress and its watchdog. Every transition is one compare-and-swap, so
//! the two threads never both act on the same stage.
const std = @import("std");

pub const State = enum(u8) { starting, waiting, committing, settled, expired, abandoned };

pub const Window = struct {
    state: std.atomic.Value(State) = .init(.starting),

    /// The peer may write its bound reply only after this returns true.
    pub fn open(self: *Window) bool {
        return self.move(.starting, .waiting);
    }

    /// The watchdog may end a peer that never became bound only after this
    /// returns true, and from then on no bound reply is written.
    pub fn unready(self: *Window) bool {
        return self.move(.starting, .expired);
    }

    /// The peer may rename only after this returns true.
    pub fn claim(self: *Window) bool {
        return self.move(.waiting, .committing);
    }

    /// The watchdog may end a peer that never saw COMMIT only after this
    /// returns true, and from then on no COMMIT is honored.
    pub fn expire(self: *Window) bool {
        return self.move(.waiting, .expired);
    }

    /// The rename call has returned, whatever it reported. The peer may
    /// write its done reply only after this returns true.
    pub fn settle(self: *Window) bool {
        return self.move(.committing, .settled);
    }

    /// The watchdog may end a peer whose rename call has not returned only
    /// after this returns true, and from then on no done reply is written.
    pub fn abandon(self: *Window) bool {
        return self.move(.committing, .abandoned);
    }

    pub fn settled(self: *const Window) bool {
        return self.state.load(.seq_cst) == .settled;
    }

    fn move(self: *Window, from: State, to: State) bool {
        return self.state.cmpxchgStrong(from, to, .seq_cst, .seq_cst) == null;
    }
};
