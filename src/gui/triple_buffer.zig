//! The lock-free snapshot handoff between the emulator and UI threads
//! (RA8EMU-227). Three slots: the writer fills its back slot and publishes
//! it by swapping it with the shared middle slot; the reader swaps the
//! middle into its front slot only when a fresh one is there. Neither side
//! ever waits on the other, a publish never touches the slot being read,
//! and a reader slower than the writer just sees the newest publish.
const std = @import("std");

pub fn TripleBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        const fresh: u8 = 0b100;
        const index: u8 = 0b011;

        slots: [3]T,
        /// The middle slot's index, plus `fresh` once the writer put it there.
        shared: std.atomic.Value(u8) = .init(1),
        back: u8 = 0,
        front: u8 = 2,
        published: u64 = 0,

        pub fn init(initial: T) Self {
            return .{ .slots = .{ initial, initial, initial } };
        }

        /// Writer: the slot to fill before `publish`.
        pub fn writeSlot(self: *Self) *T {
            return &self.slots[self.back];
        }

        /// Writer: hand the filled slot over; the writer gets the old middle.
        pub fn publish(self: *Self) void {
            const old = self.shared.swap(self.back | fresh, .acq_rel);
            self.back = old & index;
            self.published += 1;
        }

        /// Reader: the newest published slot when one arrived since the
        /// last call, else null. The slot stays valid until the next call.
        pub fn latest(self: *Self) ?*const T {
            if (self.shared.load(.acquire) & fresh == 0) return null;
            const old = self.shared.swap(self.front, .acq_rel);
            self.front = old & index;
            return &self.slots[self.front];
        }

        /// Reader: the slot it holds now, fresh or not.
        pub fn current(self: *const Self) *const T {
            return &self.slots[self.front];
        }
    };
}
