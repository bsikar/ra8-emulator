//! Pacing decisions for the shell's LCD pane (RA8EMU-824, piece 3 of 5 under
//! RA8EMU-205). Pure model over a caller-provided clock: frames arrive with
//! their virtual stamps at a wall time, and at any later wall time the pacer
//! says which pending frame shows and what was skipped. At or above real-time
//! speed the newest pending frame shows whenever the refresh cap allows, and
//! the frames dropped before it are counted for the pane's corner. Below real
//! time each pending frame waits for its scaled wall-clock slot and shows in
//! order, so an animation the guest plays in milliseconds stays watchable at
//! a tenth of real time. No SDL and no session here; the host tests drive it
//! with a fake clock.
const std = @import("std");
const speed_field = @import("speed_field.zig");

/// The cap when the display gives no vsync: one present per 60 Hz refresh.
pub const default_cap_hz: u64 = 60;

/// The frames the queue holds before the oldest pending one is dropped.
pub const depth: usize = 8;

/// Which pending frame shows at a wall time, and what was skipped.
pub const Decision = struct {
    /// The frame to show: its arrival number, counting from 1.
    generation: u64,
    /// Arrivals dropped without being shown since the last present.
    skipped: u64,
};

/// The first arrival's virtual stamp and wall time, the slot origin.
const Base = struct { v: u64, a: i128 };

pub const Pacer = struct {
    /// The shortest wall time between presents.
    cap_interval_ns: u64 = std.time.ns_per_s / default_cap_hz,
    /// The speed factor in thousandths (1000 = real time); 0 means paused.
    milli: u64 = speed_field.real_time,
    /// Virtual stamps of the pending frames, oldest first.
    stamps: [depth]u64 = undefined,
    /// The wall-clock slot each pending frame waits for.
    slots: [depth]i128 = undefined,
    count: usize = 0,
    arrivals: u64 = 0,
    skipped: u64 = 0,
    last_ns: ?i128 = null,
    base: ?Base = null,

    /// A frame stamped `virtual_ns` arrived at wall time `at_ns`. The wall
    /// time only anchors the first frame; later frames wait for their
    /// scaled slots, derived from the stamps.
    pub fn arrive(self: *Pacer, virtual_ns: u64, at_ns: i128) void {
        if (self.count == depth) {
            self.shift(1);
            self.skipped += 1;
        }
        if (self.base) |b| {
            self.stamps[self.count] = virtual_ns;
            self.slots[self.count] = b.a + @as(i128, @intCast(self.scaled(virtual_ns -| b.v)));
        } else {
            self.base = .{ .v = virtual_ns, .a = at_ns };
            self.stamps[self.count] = virtual_ns;
            self.slots[self.count] = at_ns;
        }
        self.count += 1;
        self.arrivals += 1;
    }

    /// Which frame shows at `now_ns`, if any: at most one per refresh cap,
    /// the newest pending one at or above real time and the oldest whose
    /// scaled slot has come below it. A queue that filled dropped its
    /// oldest; those drops ride along in `skipped`.
    pub fn due(self: *const Pacer, now_ns: i128) ?Decision {
        if (self.count == 0) return null;
        if (self.last_ns) |last| {
            if (now_ns - last < @as(i128, @intCast(self.cap_interval_ns))) return null;
        }
        const first = self.arrivals - self.count + 1;
        if (self.milli < speed_field.real_time) {
            if (self.slots[0] > now_ns) return null;
            return .{ .generation = first, .skipped = self.skipped };
        }
        return .{ .generation = self.arrivals, .skipped = @as(u64, self.count - 1) + self.skipped };
    }

    /// The decision's frame was shown at `now_ns`: everything up to and
    /// including it leaves the queue and the corner count resets.
    pub fn present(self: *Pacer, shown: u64, now_ns: i128) void {
        const first = self.arrivals - self.count + 1;
        if (shown < first or shown > self.arrivals) return;
        self.shift(@intCast(shown - first + 1));
        self.skipped = 0;
        self.last_ns = now_ns;
    }

    /// The wall duration the speed factor scales `guest_ns` to; a factor at
    /// or above real time compresses to nothing, so the cap alone gates.
    fn scaled(self: *const Pacer, guest_ns: u64) u64 {
        if (self.milli == 0 or self.milli >= speed_field.real_time) return 0;
        return @intCast(@as(u128, guest_ns) * speed_field.real_time / self.milli);
    }

    fn shift(self: *Pacer, drop: usize) void {
        const keep = self.count - drop;
        std.mem.copyForwards(u64, self.stamps[0..keep], self.stamps[drop .. drop + keep]);
        std.mem.copyForwards(i128, self.slots[0..keep], self.slots[drop .. drop + keep]);
        self.count = keep;
    }
};
