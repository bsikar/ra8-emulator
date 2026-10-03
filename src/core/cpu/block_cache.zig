//! Formed blocks kept by start address (RA8EMU-405).
//!
//! `next` hands `Cpu.step` the instruction at the PC with its decode, from
//! the block it is walking when the PC is the next entry, else from the
//! block that starts at the PC, formed on a miss. Every entry is checked
//! against the halfwords now in memory before it is handed out, so rewritten
//! code never runs stale; RA8EMU-404 replaces that check with invalidation
//! on writes. A null answer sends the step down its own fetch and decode,
//! which reports any fault or unknown encoding exactly as before.
const Instr = @import("instr.zig").Instr;
const bus = @import("bus.zig");
const decode = @import("decode.zig");
const block = @import("block.zig");

/// Direct-mapped by start address; a power of two.
pub const slots: usize = 1024;

pub const BlockCache = struct {
    blocks: [slots]block.Block,
    decoded: decode.cache.DecodeCache,
    current: ?*block.Block,
    index: usize,
    /// Blocks formed, blocks found already formed, and entries whose memory
    /// had changed since they were formed.
    formed: u64,
    reused: u64,
    stale: u64,

    /// Set up in place: the cache is too large to build on the stack.
    pub fn init(self: *BlockCache) void {
        for (&self.blocks) |*one| {
            one.start = 0;
            one.len = 0;
        }
        self.decoded = .{};
        self.current = null;
        self.index = 0;
        self.formed = 0;
        self.reused = 0;
        self.stale = 0;
    }

    /// The instruction at `address` and its decode, or null to step it the
    /// slow way.
    pub fn next(self: *BlockCache, from: bus.Bus, core: decode.profile.Profile, address: u32) ?block.Entry {
        if (self.current) |walking| {
            if (self.index < walking.len and walking.entries[self.index].instr.address == address)
                return self.take(from, walking);
        }
        const found = &self.blocks[(address >> 1) & (slots - 1)];
        if (found.len != 0 and found.start == address) {
            self.reused += 1;
        } else {
            found.* = block.Block.form(from, &self.decoded, core, address);
            self.formed += 1;
        }
        self.current = found;
        self.index = 0;
        return self.take(from, found);
    }

    fn take(self: *BlockCache, from: bus.Bus, walking: *block.Block) ?block.Entry {
        if (self.index >= walking.len) return self.leave();
        const kept = walking.entries[self.index];
        const now = Instr.fetch(from, kept.instr.address) catch return self.leave();
        if (now.size != kept.instr.size or now.hw1 != kept.instr.hw1 or now.hw2 != kept.instr.hw2) {
            walking.len = 0;
            self.stale += 1;
            return self.leave();
        }
        self.index += 1;
        return kept;
    }

    fn leave(self: *BlockCache) ?block.Entry {
        self.current = null;
        return null;
    }
};
