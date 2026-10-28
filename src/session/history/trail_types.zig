//! The trail's records: what a write replaced and who wrote it, the
//! structural barriers between them, and the noncore-write watches.
const std = @import("std");
const memory = @import("ra8_chip").core.cpu.memory;
const observer = memory.observer;
const Initiator = memory.initiator.Initiator;

const Allocator = std.mem.Allocator;

/// Which side of the machine a record's write came from, in the trail's
/// own position terms.
pub const Source = union(enum) {
    /// A core wrote during its own slot: `slots` is the core's cumulative
    /// slot count when the write left, so the record sits in that core's
    /// retire gap for that slot.
    core: struct { core: Core, slots: u64 },
    /// A board-phase writer (the NPU's DMA, a DTC, the display, ...): its
    /// write lands at the board phase of its round.
    board: Initiator,
    /// Untimed setup, whose writes carry no initiator of their own.
    untimed,
};

/// The two cores, in round order.
pub const Core = enum(u1) { cpu0, cpu1 };

/// One byte record: what a write was about to replace, and where it lands.
pub const Bytes = struct {
    /// The canonical base of the space the write hit: the memory region's
    /// base for store-space records, the part's own origin for part-space
    /// ones.
    base: u32,
    offset: u64,
    initiator: Initiator,
    source: Source,
    /// The part index when the record came from a component's own hooks,
    /// null from the machine store's.
    part: ?u16,
    /// The bytes the storage held before the write, owned by the trail.
    pre: []u8,

    pub fn deinit(self: *Bytes, allocator: Allocator) void {
        allocator.free(self.pre);
    }
};

/// The trail's records in arrival order.
pub const Record = union(enum) {
    bytes: Bytes,
    /// A structural change around byte writes (H5/H6).
    barrier: observer.Barrier,
};

/// A labelled noncore-write watch (unit 09): every write outside the two
/// cores whose bytes overlap the watched range raises one labelled hit.
pub const Watch = struct {
    base: u32,
    size: u32,
    /// The trail's own copy of the caller's label.
    label: []u8,
};

/// One watch hit: which watch, what range the write covered, and who
/// drove it as far as the trail can see.
pub const Hit = struct {
    watch: usize,
    start: u64,
    len: u64,
    initiator: Initiator,
    source: Source,
};

/// A component's own restore, in the component's own address space: the
/// raw overwrite past its write semantics, the counterpart of the hook
/// that recorded the bytes.
pub const PartRestore = struct {
    ctx: *anyopaque,
    raw: *const fn (ctx: *anyopaque, address: u32, bytes: []const u8) void,
};
