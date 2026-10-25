//! One reverse-window slot's change to the machine state that lives beside
//! guest memory (section 2.5): the cores, the scheduler grid, the clocks,
//! the debug units and the board, as the save stream without its memory
//! sections carries them.
//!
//! Two consecutive images of that stream are almost always the same length
//! and differ in a handful of bytes, so the delta keeps only the differing
//! runs, XORed: applying the same runs to either image yields the other,
//! which makes one delta serve both undo and redo. An image whose length
//! changed keeps both whole images instead.
//!
//! The delta also says whether any changed byte lies outside the core and
//! clock sections, because such a slot touched the board and is restored
//! through the board's sections rather than by the core-only fast path.
const std = @import("std");
const file = @import("ra8_board").snapshot.run.file;

const Allocator = std.mem.Allocator;

/// Two changed bytes this close are folded into one run: the run header
/// would cost more than the bytes between them.
pub const merge_gap: usize = 8;

/// One changed run of the image.
pub const Run = struct { offset: u32, len: u32 };

pub const Delta = struct {
    /// The changed runs and their XORed bytes, for equal-length images.
    runs: []Run = &.{},
    xor: []u8 = &.{},
    /// Both whole images, when the length changed.
    pre: []u8 = &.{},
    post: []u8 = &.{},
    /// A changed byte lies outside the core and clock sections.
    board: bool = false,

    pub fn deinit(self: *Delta, allocator: Allocator) void {
        allocator.free(self.runs);
        allocator.free(self.xor);
        allocator.free(self.pre);
        allocator.free(self.post);
        self.* = undefined;
    }

    /// The heap bytes the delta holds, for the window's byte budget. The
    /// struct itself is counted with the slot that embeds it.
    pub fn bytes(self: *const Delta) usize {
        return self.runs.len * @sizeOf(Run) + self.xor.len + self.pre.len + self.post.len;
    }

    /// Turns `image` from one side of the delta into the other. `forward`
    /// matters only for a length change; XORed runs are their own inverse.
    pub fn flip(self: *const Delta, allocator: Allocator, image: *std.ArrayList(u8), forward: bool) !void {
        if (self.pre.len != 0 or self.post.len != 0) {
            const next = if (forward) self.post else self.pre;
            image.clearRetainingCapacity();
            try image.appendSlice(allocator, next);
            return;
        }
        var at: usize = 0;
        for (self.runs) |run| {
            const span = image.items[run.offset..][0..run.len];
            for (span, self.xor[at..][0..run.len]) |*byte, x| byte.* ^= x;
            at += run.len;
        }
    }
};

/// The delta that turns `pre` into `post`.
pub fn encode(allocator: Allocator, pre: []const u8, post: []const u8) !Delta {
    if (pre.len != post.len) {
        const pre_copy = try allocator.dupe(u8, pre);
        errdefer allocator.free(pre_copy);
        return .{ .pre = pre_copy, .post = try allocator.dupe(u8, post), .board = true };
    }
    var runs: std.ArrayList(Run) = .empty;
    errdefer runs.deinit(allocator);
    var total: usize = 0;
    var i: usize = 0;
    while (i < pre.len) : (i += 1) {
        if (pre[i] == post[i]) continue;
        if (runs.items.len > 0) {
            const last = &runs.items[runs.items.len - 1];
            const last_end = @as(usize, last.offset) + last.len;
            if (i - last_end <= merge_gap) {
                total += i + 1 - last_end;
                last.len = @intCast(i + 1 - last.offset);
                continue;
            }
        }
        try runs.append(allocator, .{ .offset = @intCast(i), .len = 1 });
        total += 1;
    }
    const xor = try allocator.alloc(u8, total);
    errdefer allocator.free(xor);
    var at: usize = 0;
    for (runs.items) |run| {
        for (xor[at..][0..run.len], pre[run.offset..][0..run.len], post[run.offset..][0..run.len]) |*x, a, b| x.* = a ^ b;
        at += run.len;
    }
    const owned = try runs.toOwnedSlice(allocator);
    errdefer allocator.free(owned);
    return .{ .runs = owned, .xor = xor, .board = try touchesBoard(post, owned) };
}

/// The sections a core-only restore puts back; every other section belongs
/// to the board and its attachments.
pub fn coreSection(kind: file.Kind) bool {
    return switch (kind) {
        .cpu, .image, .systick, .stretch, .grid, .second, .debug_units, .session_runtime => true,
        else => false,
    };
}

/// Whether any run lies outside a core section of `image`. Bytes outside
/// every section (the header) count as the board's.
pub fn touchesBoard(image: []const u8, runs: []const Run) !bool {
    if (runs.len == 0) return false;
    var reader = try file.Reader.open(image);
    var spans: [64]struct { lo: usize, hi: usize } = undefined;
    var count: usize = 0;
    while (true) {
        const before = reader.at;
        const section = try reader.next() orelse break;
        if (!coreSection(section.kind)) continue;
        if (count == spans.len) return true;
        spans[count] = .{ .lo = before, .hi = reader.at };
        count += 1;
    }
    outer: for (runs) |run| {
        const lo: usize = run.offset;
        const hi = lo + run.len;
        for (spans[0..count]) |span| if (lo >= span.lo and hi <= span.hi) continue :outer;
        return true;
    }
    return false;
}
