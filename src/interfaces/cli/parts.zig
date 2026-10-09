//! Everything one run accumulates, in one place.
//!
//! These are the counters and tables the hooks write into as the run goes,
//! kept together so `main` wires them once and the report reads them once.
//! Lifted out of src/main.zig when the file passed the gate's 400 lines:
//! holding the run's state is its own purpose, and it grows by a field
//! every time a slice adds a counter.
const csel = @import("../../core/csel.zig");
const tz = @import("../../core/tz.zig");
const idle = @import("../../core/idle.zig");
const hotspots = @import("../../debug/hotspots.zig");
const functions = @import("../../debug/functions.zig");
const profile = functions.profile;
const elf = @import("../../board/loader/elf.zig");
const std = @import("std");
const stack_samples = @import("../../debug/stack_samples.zig");
const tally = @import("../../debug/tally.zig");
const pc_hits = @import("../../debug/pc_hits.zig");
const clocks = @import("../../periph/clocks.zig");
const lob = @import("../../core/lob.zig");
const bus_fault = @import("../../periph/bus_fault.zig");
const console_output = @import("console_output.zig");
const second_core = @import("../../core/second_core.zig");

pub const Parts = struct {
    /// Where finished console lines go: `--console` and `--until`.
    tap: console_output.Tap = .{},
    loops: lob.Loops = .{},
    selects: csel.Selects = .{},
    clears: csel.clrm.Clears = .{},
    worlds: tz.Worlds = .{},
    idle: idle.Seam = .{},
    pcs: hotspots.Table = .{},
    fns: ?functions.Table = null,
    profile: ?profile.Table = null,
    taken: tally.Tally = .{},
    timebase: clocks.Clocks = .{},
    hits: pc_hits.Hits = .{},
    /// CPU1's image bytes, held for its folded rows' names (RA8EMU-972).
    second_bytes: ?[]u8 = null,

    /// The profile table, fed from the Zig core's retire path (RA8EMU-592),
    /// with a store for sampled call stacks when they are `sampled`
    /// (`--profile-folded`, RA8EMU-971), and CPU1's image, read from
    /// `cpu1_path`, to name its samples by (RA8EMU-972).
    pub fn prepareProfile(self: *Parts, io: std.Io, image: elf.Image, sampled: bool, cpu1_path: ?[]const u8) !void {
        self.profile = .{ .image = image };
        self.profile.?.prepare();
        if (!sampled) return;
        const store = try std.heap.page_allocator.create(stack_samples.Store);
        store.* = .{};
        self.profile.?.samples = store;
        const path = cpu1_path orelse return;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(second_core.limits.image_bytes));
        self.second_bytes = bytes;
        self.profile.?.second = try elf.Image.init(bytes);
    }

    pub fn deinit(self: *Parts) void {
        if (self.second_bytes) |bytes| std.heap.page_allocator.free(bytes);
        self.second_bytes = null;
        const table = if (self.profile) |*one| one else return;
        if (table.samples) |store| std.heap.page_allocator.destroy(store);
        table.samples = null;
    }
};
