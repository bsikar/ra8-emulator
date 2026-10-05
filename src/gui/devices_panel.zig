//! The devices panel's state (RA8EMU-703): each endpoint the run cares
//! about and the catalog part on it, with plug and unplug going through the
//! session so the event stream records them like the debugger front and
//! `--faults FILE` do.
//!
//! The panel never touches a bus. It asks the session, and only a change
//! the session accepted moves a row, so a refused plug leaves the row
//! showing what is really on the line. Drawing the panel and the clicks
//! that call these are later slices.
const std = @import("std");
const session_api = @import("../debug/session_api.zig");

pub const Endpoint = session_api.Endpoint;

/// One endpoint and what is on it now; `part` is null while it is empty.
pub const Row = struct {
    at: Endpoint,
    part: ?[]const u8,
};

pub const Panel = struct {
    session: *session_api.Session,
    /// Owned by the caller, one per endpoint the panel lists.
    rows: []Row,
    /// The core the session records the change against.
    core: session_api.Core = .cpu0,

    /// Take whatever is on row `index` off its endpoint.
    pub fn unplug(self: *Panel, index: usize) anyerror!void {
        const row = &self.rows[index];
        try self.session.unplug(self.core, row.at);
        row.part = null;
    }

    /// Put a fresh catalog part `name` on row `index`'s endpoint.
    pub fn plug(self: *Panel, index: usize, name: []const u8) anyerror!void {
        const row = &self.rows[index];
        try self.session.plug(self.core, row.at, name);
        row.part = name;
    }

    /// The panel's one-click action: unplug a fitted row, or put `name`
    /// back on an empty one.
    pub fn toggle(self: *Panel, index: usize, name: []const u8) anyerror!void {
        if (self.rows[index].part == null) return self.plug(index, name);
        return self.unplug(index);
    }

    /// The row listing `at`, if the panel lists it.
    pub fn find(self: Panel, at: Endpoint) ?usize {
        for (self.rows, 0..) |row, index| {
            if (std.meta.eql(row.at, at)) return index;
        }
        return null;
    }
};
