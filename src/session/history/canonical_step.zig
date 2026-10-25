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

/// Stepi(S): lands at the next canonical stop of `core`.
pub fn stepForward(w: *ReverseWindow, core: Core) !Landed {
    var landed: Landed = .{};
    var next = w.cursor();
    while (next < w.count() and w.slotAt(next).core != core) next += 1;
    if (next == w.count()) return Error.OutsideWindow;
    while (w.cursor() <= next) landed.cross(try redoOne(w), core);
    while (w.cursor() < w.count() and w.slotAt(w.cursor()).core != core) landed.cross(try redoOne(w), core);
    landed.at_window_end = w.cursor() == w.count();
    return landed;
}

/// Reverse-stepi(S): lands at the previous canonical stop of `core`.
pub fn stepBack(w: *ReverseWindow, core: Core) !Landed {
    var landed: Landed = .{};
    var last = w.cursor();
    while (last > 0 and w.slotAt(last - 1).core != core) last -= 1;
    if (last == 0) return Error.OutsideWindow;
    while (w.cursor() >= last) landed.cross(try undoOne(w), core);
    return landed;
}

fn redoOne(w: *ReverseWindow) !*engine.Slot {
    const slot = w.slotAt(w.cursor());
    _ = try w.redo();
    return slot;
}

fn undoOne(w: *ReverseWindow) !*engine.Slot {
    const slot = w.slotAt(w.cursor() - 1);
    _ = try w.undo();
    return slot;
}
