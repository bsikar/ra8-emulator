//! The hook sites a recording run feeds the trail through (RA8EMU-D1).
//!
//! Two byte hooks and a set of barriers cover every guest-visible mutation
//! the trail must catch:
//!
//!  - `Store.write` (H1): the pre-image from the store's own backing, with
//!    the initiator that made the write. OSPI-backed writes defer to the
//!    Flash model's own hooks (H3): a NOR write is not a byte overwrite
//!    and must not be recorded as one.
//!  - `DirectMemory.write` (H2): the core's fast path, the same pre-image
//!    contract. A run may instead disable fast writes while recording.
//!  - Barriers (H5): `Store.wipe`, `Store.attachExternal`, `Store.map`,
//!    and a snapshot load's commit. `Extra.deinit` happens inside a wipe
//!    or teardown, so the wipe barrier covers it.
//!
//! The identity of a write is the canonical backing region's base plus the
//! offset inside it, so the Non-secure aliases and a borrower's shared
//! regions fold onto the same storage a restore replays into. The
//! pre-image is valid only during the call; the trail copies it.
//!
//! Hooks are per machine: each store holds its own observer, a borrower
//! store feeds its lender's, and nothing here is global.
const Initiator = @import("initiator.zig").Initiator;

/// A byte write about to happen: the storage it lands on, where inside it,
/// who wrote, and the bytes there before.
pub const Write = struct {
    base: u32,
    offset: u64,
    initiator: Initiator,
    /// The bytes the storage holds before the write. Valid only during the
    /// observer call.
    pre: []const u8,
};

/// A structural change around byte writes.
pub const Barrier = union(enum) {
    /// `Store.wipe`: owned regions zeroed, mapped windows dropped.
    wipe,
    /// A snapshot load's commit: regions zeroed, windows replaced, bytes
    /// applied.
    snapshot_load,
    /// `Store.attachExternal`: the SDRAM aperture now reaches the board's
    /// backing.
    attach_external,
    /// `Store.map`: a fresh zeroed window opened.
    mapped: struct { base: u32, size: u32 },
};

pub const Observer = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        bytes: *const fn (ctx: *anyopaque, write: Write) void,
        barrier: *const fn (ctx: *anyopaque, event: Barrier) void,
    };

    pub fn bytes(self: Observer, write: Write) void {
        self.vtable.bytes(self.ctx, write);
    }

    pub fn barrier(self: Observer, event: Barrier) void {
        self.vtable.barrier(self.ctx, event);
    }
};
