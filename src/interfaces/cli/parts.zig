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
const unmask = @import("../../core/unmask.zig");
const hotspots = @import("../../debug/hotspots.zig");
const functions = @import("../../debug/functions.zig");
const profile = functions.profile;
const elf = @import("../../core/elf.zig");
const std = @import("std");
const stack_samples = @import("../../debug/stack_samples.zig");
const tally = @import("../../debug/tally.zig");
const pend_break = @import("../../core/pend_break.zig");
const pend_pace = @import("../../core/pend_pace.zig");
const mask_pace = @import("../../core/mask_pace.zig");
const pc_hits = @import("../../debug/pc_hits.zig");
const clocks = @import("../../periph/clocks.zig");
const lob = @import("../../core/lob.zig");
const bus_fault = @import("../../periph/bus_fault.zig");
const console_output = @import("console_output.zig");

pub const Parts = struct {
    /// Where finished console lines go: `--console` and `--until`.
    tap: console_output.Tap = .{},
    loops: lob.Loops = .{},
    selects: csel.Selects = .{},
    clears: csel.clrm.Clears = .{},
    worlds: tz.Worlds = .{},
    idle: idle.Seam = .{},
    release: unmask.Release = .{},
    pcs: hotspots.Table = .{},
    fns: ?functions.Table = null,
    profile: ?profile.Table = null,
    taken: tally.Tally = .{},
    timebase: clocks.Clocks = .{},
    pend: pend_break.Pend = .{},
    pacing: pend_pace.Pace = .{},
    mask_pacing: mask_pace.Pace = .{},
    hits: pc_hits.Hits = .{},

    /// The profile table, fed from the Zig core's retire path (RA8EMU-592),
    /// with a store for sampled call stacks when they are `sampled`
    /// (`--profile-folded`, RA8EMU-971).
    pub fn prepareProfile(self: *Parts, image: elf.Image, sampled: bool) !void {
        self.profile = .{ .image = image };
        self.profile.?.prepare();
        if (!sampled) return;
        const store = try std.heap.page_allocator.create(stack_samples.Store);
        store.* = .{};
        self.profile.?.samples = store;
    }

    pub fn deinit(self: *Parts) void {
        const table = if (self.profile) |*one| one else return;
        if (table.samples) |store| std.heap.page_allocator.destroy(store);
        table.samples = null;
    }
};
