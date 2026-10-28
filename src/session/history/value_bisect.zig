//! Value bisection: deciding, from the checkpoint engine's record of which
//! pages were written, that a watched range cannot have changed inside an
//! interval.
//!
//! The rule is "not written at all", never "same contents at both ends":
//! equal page hashes cannot rule out a change and change-back (A to B to A)
//! inside the interval, and that is a real change a reverse search must
//! stop at. An interval is skippable only when a record exists and every
//! watched page is absent from it. No record, or no pages to check, means
//! the interval is replayed.
//!
//! This only speeds up a search for the latest write that changed a value;
//! a plain watch never consults it.
const touched_pages = @import("touched_pages.zig");

pub const PageKey = touched_pages.PageKey;
pub const Touched = touched_pages.Touched;

/// Whether no watched page was written across the interval from
/// checkpoint `since` that `touched` describes. Null (no record), or a
/// record that starts at a different checkpoint (one between was thinned
/// away, so the record covers less than the interval), is never skippable.
pub fn untouched(touched: ?*const Touched, since: u32, pages: []const PageKey) bool {
    const record = touched orelse return false;
    if (record.since != since) return false;
    if (pages.len == 0) return false;
    for (pages) |key| if (record.isTouched(key)) return false;
    return true;
}
