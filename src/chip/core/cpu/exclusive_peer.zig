//! The global half of the exclusive monitor across the two cores
//! (RA8EMU-134). Each core's local monitor is its `Cpu.exclusive` tag. A
//! store either core makes into the aligned word the other core tagged
//! clears that tag, so the other core's next STREX fails, as the global
//! monitor does on silicon. CLREX, exception entry and return stay local.
const Cpu = @import("cpu.zig").Cpu;

/// The other core's local monitor, as one core's bus sees it.
pub const Peer = struct {
    tag: *?u32,

    /// A store of `len` bytes at `address` landed: clear the other core's
    /// tag when the store touches the word it covers.
    pub fn stored(self: Peer, address: u32, len: usize) void {
        const tagged = self.tag.* orelse return;
        const word: u64 = tagged & ~@as(u32, 3);
        const start: u64 = address;
        if (start < word + 4 and start + len > word) self.tag.* = null;
    }
};

/// Make `a` and `b` watch each other's stores, on the buses they hold now.
pub fn pair(a: *Cpu, b: *Cpu) void {
    a.bus.peer = .{ .tag = &b.exclusive };
    b.bus.peer = .{ .tag = &a.exclusive };
}

/// Stop both cores watching: `a` is going away.
pub fn unpair(a: *Cpu, b: *Cpu) void {
    a.bus.peer = null;
    b.bus.peer = null;
}
