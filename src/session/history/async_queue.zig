//! Bounded asynchronous host-traffic queue for packet row 20.
//!
//! Asynchronous host traffic (such as ESP32-C6 hosted network bytes/answers,
//! USB/IP host URBs, and camera video frames) arriving while the machine's
//! cursor is rewound in the past does not fork execution lines. Instead,
//! it accumulates in this bounded FIFO queue until the cursor catches up
//! to the recorded end, at which point it drains in arrival order into the
//! live run.
//!
//! If the execution line diverges (for instance, an intervention forks the
//! past into a new line, disconnecting the network), `clear` purges the
//! pending traffic and returns a report of discarded items.
//!
//! ## Overflow Policy: Tail-Drop (Refuse Newest) Rationale
//!
//! The queue enforces a fixed byte capacity (defaulting to 16 MiB). Each item
//! accounts for its payload length plus a fixed per-item overhead (`item_overhead`),
//! guaranteeing an honest memory bound that cannot be bypassed by enqueueing
//! zero-byte or tiny packets.
//!
//! When an incoming item cannot fit within the remaining capacity (or is itself
//! larger than the total queue capacity), the queue refuses the item (tail-drop)
//! and latches visible overflow metrics (drop counts and byte totals per source,
//! and the timestamp of the first drop).
//!
//! Refusing the newest item rather than evicting the oldest queued item is the
//! safe and correct choice for ordered streams (such as TCP flows across the C6
//! network bridge and USB/IP URB transaction streams):
//!
//! 1. Contiguous Stream Integrity:
//!    Protocols like TCP depend strictly on contiguous byte streams without gaps.
//!    Evicting the oldest item introduces a silent hole at the head of the stream.
//!    When the guest later resumes live execution and drains the queue, it would
//!    receive subsequent packets without preceding ones, causing immediate protocol
//!    desynchronization, checksum/sequence failures, and broken connection state.
//!
//! 2. Transport Semantics:
//!    Refusing newest items at the boundary mirrors real network buffer drops
//!    (tail drop) or receiver window limits. TCP endpoints detect packet drops via
//!    missing ACKs and trigger normal retransmission, keeping the already-accepted
//!    prefix intact and reliable.
//!
//! 3. Determinism:
//!    Items already accepted into the queue during rewound replay form an established
//!    input prefix. Silently mutating that prefix by evicting older items invalidates
//!    repeatable replay. Tail-drop keeps the accepted prefix immutable.
const std = @import("std");

/// The default maximum queue capacity in bytes (16 MiB).
pub const default_capacity: usize = 16 * 1024 * 1024;

/// Fixed per-item memory overhead charged against capacity in bytes.
///
/// Accounts for internal node bookkeeping, source tag, timestamp, and slice
/// pointers, ensuring honest byte bounding even with zero-length payloads.
pub const item_overhead: usize = 32;

/// The source category of asynchronous host traffic.
pub const Source = enum(u8) {
    /// ESP32-C6 hosted network payload bytes (e.g. inbound TCP/UDP packets).
    c6_bytes = 0,
    /// ESP32-C6 hosted network asynchronous control answers / responses.
    c6_answer = 1,
    /// USB/IP host-to-device URB packets.
    usbip = 2,
    /// Host camera frame captures.
    camera = 3,
};

/// Total number of distinct source categories.
pub const source_count: usize = 4;

/// An item delivered to a drain visitor.
pub const Item = struct {
    /// The origin of this asynchronous traffic.
    source: Source,
    /// The arrival timestamp in host nanoseconds.
    arrival_ns: u64,
    /// The opaque payload bytes.
    data: []const u8,
};

/// Latched overflow telemetry recorded when items are refused.
pub const OverflowState = struct {
    /// Count of dropped items per source.
    dropped_items: [source_count]u64 = @splat(0),
    /// Count of dropped payload bytes per source.
    dropped_bytes: [source_count]u64 = @splat(0),
    /// Host timestamp in nanoseconds of the first refused item, or null if clean.
    first_drop_ns: ?u64 = null,

    /// Whether any item has been refused due to overflow.
    pub fn hasDropped(self: OverflowState) bool {
        return self.first_drop_ns != null;
    }

    /// Total count of dropped items across all sources.
    pub fn totalDroppedItems(self: OverflowState) u64 {
        var sum: u64 = 0;
        for (self.dropped_items) |c| sum += c;
        return sum;
    }

    /// Total count of dropped payload bytes across all sources.
    pub fn totalDroppedBytes(self: OverflowState) u64 {
        var sum: u64 = 0;
        for (self.dropped_bytes) |b| sum += b;
        return sum;
    }

    /// Count of dropped items for a specific source.
    pub fn droppedItemsFor(self: OverflowState, source: Source) u64 {
        return self.dropped_items[@backingInt(source)];
    }

    /// Count of dropped payload bytes for a specific source.
    pub fn droppedBytesFor(self: OverflowState, source: Source) u64 {
        return self.dropped_bytes[@backingInt(source)];
    }
};

/// Report of items discarded when the queue is cleared.
pub const DiscardReport = struct {
    /// Total count of items discarded.
    items: usize = 0,
    /// Total payload bytes discarded.
    bytes: usize = 0,
    /// Count of discarded items per source.
    items_by_source: [source_count]usize = @splat(0),
    /// Count of discarded payload bytes per source.
    bytes_by_source: [source_count]usize = @splat(0),

    /// Count of discarded items for a specific source.
    pub fn itemsFor(self: DiscardReport, source: Source) usize {
        return self.items_by_source[@backingInt(source)];
    }

    /// Count of discarded payload bytes for a specific source.
    pub fn bytesFor(self: DiscardReport, source: Source) usize {
        return self.bytes_by_source[@backingInt(source)];
    }
};

const Node = struct {
    next: ?*Node = null,
    source: Source,
    arrival_ns: u64,
    payload_len: usize,

    fn payload(self: *Node) []u8 {
        const ptr: [*]u8 = @as([*]u8, @ptrCast(self)) + @sizeOf(Node);
        return ptr[0..self.payload_len];
    }

    // The charged overhead must cover the real header, or the bound lies.
    comptime {
        std.debug.assert(@sizeOf(Node) <= item_overhead);
    }
};

/// Pure bounded asynchronous host-traffic queue.
pub const AsyncQueue = struct {
    allocator: std.mem.Allocator,
    max_capacity: usize,
    used_bytes: usize = 0,
    item_count: usize = 0,
    head: ?*Node = null,
    tail: ?*Node = null,
    overflow: OverflowState = .{},

    /// Initializes an asynchronous traffic queue with a fixed capacity.
    /// If cap is 0, defaults to `default_capacity` (16 MiB).
    pub fn init(allocator: std.mem.Allocator, cap: usize) AsyncQueue {
        const actual = if (cap == 0) default_capacity else cap;
        return .{
            .allocator = allocator,
            .max_capacity = actual,
        };
    }

    /// Frees all queued items and resets queue state.
    pub fn deinit(self: *AsyncQueue) void {
        _ = self.clear();
        self.* = undefined;
    }

    /// Appends an item to the queue. Returns true if accepted, or false if
    /// refused due to overflow (or oversize), latching overflow state.
    pub fn push(self: *AsyncQueue, source: Source, arrival_ns: u64, data: []const u8) !bool {
        const item_cost = item_overhead + data.len;
        if (item_cost > self.max_capacity or self.used_bytes + item_cost > self.max_capacity) {
            self.recordDrop(source, arrival_ns, data.len);
            return false;
        }

        const alloc_size = @sizeOf(Node) + data.len;
        const bytes = try self.allocator.alignedAlloc(u8, .of(Node), alloc_size);
        const node: *Node = @ptrCast(@alignCast(bytes.ptr));
        node.* = .{
            .next = null,
            .source = source,
            .arrival_ns = arrival_ns,
            .payload_len = data.len,
        };
        @memcpy(node.payload(), data);

        if (self.tail) |t| {
            t.next = node;
        } else {
            self.head = node;
        }
        self.tail = node;

        self.used_bytes += item_cost;
        self.item_count += 1;
        return true;
    }

    /// Drains all queued items in arrival order into the visitor.
    /// Returns the number of items delivered.
    pub fn drain(self: *AsyncQueue, visitor: anytype) !usize {
        const VisitorType = @TypeOf(visitor);
        const has_visit = comptime if (@typeInfo(VisitorType) == .pointer and @typeInfo(std.meta.Child(VisitorType)) == .@"struct")
            @hasDecl(std.meta.Child(VisitorType), "visit")
        else if (@typeInfo(VisitorType) == .@"struct")
            @hasDecl(VisitorType, "visit")
        else
            false;

        var delivered: usize = 0;
        while (self.head) |node| {
            const item = Item{
                .source = node.source,
                .arrival_ns = node.arrival_ns,
                .data = node.payload(),
            };
            const res = if (comptime has_visit)
                visitor.visit(item)
            else
                visitor(item);
            if (@typeInfo(@TypeOf(res)) == .error_union) {
                try res;
            }
            _ = self.popNode();
            self.freeNode(node);
            delivered += 1;
        }
        return delivered;
    }

    /// Clears all queued items and returns a summary of what was discarded.
    pub fn clear(self: *AsyncQueue) DiscardReport {
        var report = DiscardReport{};
        while (self.popNode()) |node| {
            report.items += 1;
            report.bytes += node.payload_len;
            report.items_by_source[@backingInt(node.source)] += 1;
            report.bytes_by_source[@backingInt(node.source)] += node.payload_len;
            self.freeNode(node);
        }
        return report;
    }

    /// Returns whether the queue holds zero items.
    pub fn isEmpty(self: *const AsyncQueue) bool {
        return self.item_count == 0;
    }

    /// Returns the number of items currently queued.
    pub fn count(self: *const AsyncQueue) usize {
        return self.item_count;
    }

    /// Returns the total bytes consumed (payload plus overhead).
    pub fn usedBytes(self: *const AsyncQueue) usize {
        return self.used_bytes;
    }

    /// Returns the maximum capacity of the queue in bytes.
    pub fn capacity(self: *const AsyncQueue) usize {
        return self.max_capacity;
    }

    /// Returns the remaining available capacity in bytes.
    pub fn availableBytes(self: *const AsyncQueue) usize {
        if (self.used_bytes >= self.max_capacity) return 0;
        return self.max_capacity - self.used_bytes;
    }

    /// Returns the current latched overflow telemetry.
    pub fn overflowState(self: *const AsyncQueue) OverflowState {
        return self.overflow;
    }

    /// Returns whether any traffic was dropped due to overflow.
    pub fn hasOverflow(self: *const AsyncQueue) bool {
        return self.overflow.hasDropped();
    }

    /// Clears the latched overflow telemetry.
    pub fn resetOverflow(self: *AsyncQueue) void {
        self.overflow = .{};
    }

    fn recordDrop(self: *AsyncQueue, source: Source, arrival_ns: u64, payload_len: usize) void {
        if (self.overflow.first_drop_ns == null) {
            self.overflow.first_drop_ns = arrival_ns;
        }
        self.overflow.dropped_items[@backingInt(source)] += 1;
        self.overflow.dropped_bytes[@backingInt(source)] += payload_len;
    }

    fn popNode(self: *AsyncQueue) ?*Node {
        const node = self.head orelse return null;
        self.head = node.next;
        if (self.head == null) {
            self.tail = null;
        }
        self.used_bytes -= item_overhead + node.payload_len;
        self.item_count -= 1;
        return node;
    }

    fn freeNode(self: *AsyncQueue, node: *Node) void {
        const alloc_size = @sizeOf(Node) + node.payload_len;
        const mem: []align(@alignOf(Node)) u8 = @as([*]align(@alignOf(Node)) u8, @ptrCast(node))[0..alloc_size];
        self.allocator.free(mem);
    }
};
