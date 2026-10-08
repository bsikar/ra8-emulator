//! The call stacks a `--profile-folded` run samples (RA8EMU-971, slice 1 of
//! RA8EMU-955): a stack_sampler.Sampler on CPU0's retire path, in front of
//! whatever listened there before, filling the profile table's store.
//!
//! The run builds its core inside boot.start and lends it through
//! boot.Wiring.core, so the sampler is made on the first instruction the
//! core retires, once that pointer is there. Frames are named and their
//! functions found from the image's symbols; the walk uses its .debug_frame
//! where that covers the pc, else the r7 frame records (RA8EMU-956).
const std = @import("std");
const elf = @import("../../core/elf.zig");
const cpu_mod = @import("../../core/cpu/cpu.zig");
const dwarf_line = @import("../../debug/dwarf_line.zig");
const profile = @import("../../debug/profile.zig");
const rtos_trace = @import("../../debug/rtos_trace.zig");
const stack_samples = @import("../../debug/stack_samples.zig");
const stack_sampler = @import("../../debug/stack_sampler.zig");
const stack_walk = @import("../../debug/stack_walk.zig");
const symbols = @import("../../debug/symbols.zig");

pub const Run = struct {
    image: elf.Image,
    /// Null when nothing asked for samples: the run is wired as before.
    store: ?*stack_samples.Store,
    every: u32,
    clock: *const u64,
    trace: ?*const rtos_trace.Trace,
    next: ?cpu_mod.RetireListener = null,
    /// The core, lent by the run before reset and taken back after.
    core: ?*cpu_mod.Cpu = null,
    sampler: ?stack_sampler.Sampler = null,

    /// Sample when `table` carries a store, every `period(budget)`th
    /// instruction, stamped from `clock` and tagged from `trace`.
    pub fn of(table: ?*profile.Table, image: elf.Image, budget: u64, clock: *const u64, trace: ?*const rtos_trace.Trace) Run {
        const store = if (table) |found| found.samples else null;
        return .{ .image = image, .store = store, .every = period(budget), .clock = clock, .trace = trace };
    }

    /// The listener the core gets: this in front of `next`, or `next`
    /// alone when there is nothing to sample.
    pub fn listener(self: *Run, next: ?cpu_mod.RetireListener) ?cpu_mod.RetireListener {
        if (self.store == null) return next;
        self.next = next;
        return .{ .context = self, .instructionFn = instruction };
    }

    /// Where the run lends its core, or null when nothing samples.
    pub fn lend(self: *Run) ?*?*cpu_mod.Cpu {
        return if (self.store != null) &self.core else null;
    }

    fn instruction(context: *anyopaque, address: u32) void {
        const self: *Run = @ptrCast(@alignCast(context));
        const core = self.core orelse {
            if (self.next) |chained| chained.instruction(address);
            return;
        };
        if (self.sampler == null or self.sampler.?.view.zig.cpu != core) self.sampler = self.samplerOn(core);
        self.sampler.?.listener().instruction(address);
    }

    fn samplerOn(self: *const Run, core: *cpu_mod.Cpu) stack_sampler.Sampler {
        return .{
            .view = .{ .zig = .{ .cpu = core } },
            .core = 0,
            .every = self.every,
            .frame = dwarf_line.section(self.image, ".debug_frame"),
            .starts = starts(&self.image),
            .store = self.store.?,
            .trace = self.trace,
            .clock = self.clock,
            .next = self.next,
        };
    }
};

/// Spread a bounded run's samples evenly over the store: one every
/// budget / slots instructions, at least every one.
pub fn period(budget: u64) u32 {
    const spread = @max(budget / stack_samples.limits.samples, 1);
    return @intCast(@min(spread, std.math.maxInt(u32)));
}

/// Function starts out of `image`'s symbols; `image` must outlive them.
pub fn starts(image: *const elf.Image) stack_walk.Starts {
    return .{ .context = image, .startFn = startOf };
}

/// Frame names out of `image`'s symbols; `image` must outlive them.
pub fn names(image: *const elf.Image) stack_samples.Names {
    return .{ .context = image, .nameFn = nameOf };
}

fn startOf(context: *const anyopaque, address: u32) ?u32 {
    const image: *const elf.Image = @ptrCast(@alignCast(context));
    const found = symbols.inside(image.*, address) orelse return null;
    return address - found.offset;
}

fn nameOf(context: *const anyopaque, address: u32) ?[]const u8 {
    const image: *const elf.Image = @ptrCast(@alignCast(context));
    const found = symbols.inside(image.*, address) orelse return null;
    return found.name;
}
