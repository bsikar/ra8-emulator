//! The last few instructions a lockstep run executed, oldest first, so a
//! divergence report shows the path into it.
const Instr = @import("../instr.zig").Instr;

pub const depth = 8;

pub const Entry = struct {
    address: u32,
    instr: Instr,
};

pub const History = struct {
    ring: [depth]Entry = undefined,
    next: usize = 0,
    len: usize = 0,

    pub fn push(self: *History, entry: Entry) void {
        self.ring[self.next] = entry;
        self.next = (self.next + 1) % depth;
        if (self.len < depth) self.len += 1;
    }

    /// The `i`th entry still held, 0 the oldest.
    pub fn at(self: *const History, i: usize) Entry {
        const oldest = (self.next + depth - self.len) % depth;
        return self.ring[(oldest + i) % depth];
    }
};
