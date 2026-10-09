//! What is due at a virtual time (RA8EMU-179, slice RA8EMU-511).
//!
//! A timed block puts the virtual nanosecond its next event falls on here,
//! under an id of its own, and takes it back once the time base has reached
//! it. The queue is a short sorted array: a board has a few dozen timers at
//! most, and a fixed array needs no allocator at the chunk boundary. Two
//! events at the same time come out in the order they were scheduled, so a
//! run is the same every time.
pub const capacity: usize = 32;

pub const Event = struct {
    at_ns: u64,
    id: u16,
    seq: u32,
};

pub const Error = error{QueueFull};

pub const EventQueue = struct {
    items: [capacity]Event = undefined,
    count: usize = 0,
    next_seq: u32 = 0,

    pub fn schedule(self: *EventQueue, at_ns: u64, id: u16) Error!void {
        if (self.count == capacity) return Error.QueueFull;
        const event = Event{ .at_ns = at_ns, .id = id, .seq = self.next_seq };
        self.next_seq +%= 1;
        var slot = self.count;
        while (slot > 0 and self.items[slot - 1].at_ns > at_ns) : (slot -= 1) {
            self.items[slot] = self.items[slot - 1];
        }
        self.items[slot] = event;
        self.count += 1;
    }

    /// The earliest time anything is due, if anything is.
    pub fn next(self: *const EventQueue) ?u64 {
        if (self.count == 0) return null;
        return self.items[0].at_ns;
    }

    /// The earliest event due at or before `now_ns`, taken off the queue.
    pub fn popDue(self: *EventQueue, now_ns: u64) ?Event {
        if (self.count == 0 or self.items[0].at_ns > now_ns) return null;
        const first = self.items[0];
        self.removeAt(0);
        return first;
    }

    /// Drop every event under `id`, as a timer that stops or re-arms does.
    pub fn cancel(self: *EventQueue, id: u16) usize {
        var dropped: usize = 0;
        var index: usize = 0;
        while (index < self.count) {
            if (self.items[index].id == id) {
                self.removeAt(index);
                dropped += 1;
            } else {
                index += 1;
            }
        }
        return dropped;
    }

    fn removeAt(self: *EventQueue, index: usize) void {
        var at = index;
        while (at + 1 < self.count) : (at += 1) self.items[at] = self.items[at + 1];
        self.count -= 1;
    }
};
