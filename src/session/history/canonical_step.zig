//! Stepi and reverse-stepi on a reverse window (section 4).
//!
//! The canonical stop C_S(k) of core S is the position before S's slot
//! k+1, after everything that sits between S's slot k and it: the other
//! core's turn and the board tick. Window slots are in execution order,
//! so stepping S forward redoes through S's next slot and on up to the
//! stop before the slot after it, and stepping S back undoes through S's
//! latest slot behind the cursor and stops at that slot's pre-state.
//! Between canonical stops the two are exact inverses, whichever core
//! the cursor last crossed.
//!
//! A step that needs a slot outside the window refuses with
//! `OutsideWindow`: the caller rebuilds the window, or past the end runs
//! live. Nothing moves in that case.
const std = @import("std");
const engine = @import("window_engine.zig");

const ReverseWindow = engine.ReverseWindow;
const Core = engine.Core;

pub const Error = error{OutsideWindow};

/// What one step crossed besides the stepping core's own slot.
pub const Landed = struct {
    /// Slots of the other core run on the way.
    other_core_slots: usize = 0,
    /// Slots that touched the board or a part (a tick, an MMIO write).
    complex_slots: usize = 0,
    /// A forward step stopped at the window end before the stop after
    /// its slot: the canonical stop lies past the window.
    at_window_end: bool = false,

    fn cross(self: *Landed, slot: *const engine.Slot, core: Core) void {
        if (slot.core != core) self.other_core_slots += 1;
        if (slot.kind == .complex) self.complex_slots += 1;
    }
};

pub fn retiresOn(slot: *const engine.Slot, core: Core) bool {
    return slot.core == core and slot.retired;
}

/// Stepi(S): lands at the next canonical stop of `core`.
pub fn stepForward(w: *ReverseWindow, core: Core) !Landed {
    var landed: Landed = .{};
    var next = w.cursor();
    while (next < w.count() and !retiresOn(w.slotAt(next), core)) next += 1;
    if (next == w.count()) return Error.OutsideWindow;
    var target = next + 1;
    while (target < w.count() and !retiresOn(w.slotAt(target), core)) target += 1;
    const from = w.cursor();
    try w.walkTo(target);
    for (from..target) |idx| landed.cross(w.slotAt(idx), core);
    landed.at_window_end = w.cursor() == w.count();
    return landed;
}

/// Reverse-stepi(S): lands at the previous canonical stop of `core`.
pub fn stepBack(w: *ReverseWindow, core: Core) !Landed {
    var landed: Landed = .{};
    var last = w.cursor();
    while (last > 0 and !retiresOn(w.slotAt(last - 1), core)) last -= 1;
    if (last == 0) return Error.OutsideWindow;
    const target = last - 1;
    var idx = w.cursor();
    while (idx > target) {
        idx -= 1;
        landed.cross(w.slotAt(idx), core);
    }
    try w.walkTo(target);
    return landed;
}
