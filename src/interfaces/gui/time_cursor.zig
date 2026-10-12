//! The shared time cursor (RA8EMU-838): the virtual moment the debugger
//! shows state at, or null for the live run. The timeline pane's slice
//! click sets it; the time bar (RA8EMU-203) and the LCD scrubber
//! (RA8EMU-825) read it when they adopt it.
const std = @import("std");

/// The moment the debugger panes show state at.
pub const Cursor = struct {
    at_ns: ?u64 = null,

    /// Show state at `ns` from now on.
    pub fn moveTo(self: *Cursor, ns: u64) void {
        self.at_ns = ns;
    }

    /// Back to the live run.
    pub fn clear(self: *Cursor) void {
        self.at_ns = null;
    }

    pub fn isLive(self: Cursor) bool {
        return self.at_ns == null;
    }
};
