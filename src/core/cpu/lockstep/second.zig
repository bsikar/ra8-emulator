//! CPU1 in a lockstep run (RA8EMU-235). A `Pair` checks CPU1's Zig core
//! against CPU1's Unicorn engine one instruction at a time, the way
//! mode.zig checks CPU0. Each backend keeps its own memory: the Zig side
//! opens a fresh engine that shares board RAM with CPU0's Zig-side engine,
//! so both Zig cores see one SRAM, and the Unicorn side is the `Second`
//! the board already runs. CPU1 keeps its own peripheral log, so an access
//! CPU1's oracle made is replayed only to CPU1's Zig core.
//!
//! A `Pair` holds pointers into itself (the bus into its log, the CPU into
//! its bus), so it is opened in place and never copied after `open`.
const std = @import("std");
const engine = @import("../../engine.zig");
const elf = @import("../../elf.zig");
const part = @import("../../part.zig");
const cpu_mod = @import("../cpu.zig");
const ReplayBus = @import("replay_bus.zig").ReplayBus;
const periph_log = @import("periph_log.zig");
const tap_hook = @import("tap_hook.zig");
const snapshot = @import("snapshot.zig");
const oracle = @import("oracle.zig");
const seed = @import("seed.zig");
const run_mod = @import("run.zig");
const sau = @import("../../../periph/sau.zig");
const mpu = @import("../../../periph/mpu/mpu.zig");

pub const Pair = struct {
    mine: engine.Engine,
    theirs: engine.Engine,
    log: periph_log.Log = .{},
    partitions: sau.Sau,
    regions: mpu.Mpu,
    memory: ReplayBus,
    cpu: cpu_mod.Cpu,
    lock: run_mod.Run = .{},
    taps: tap_hook.Taps,
    /// Why CPU1's check ended, once it has; `turn` does nothing after that.
    ended: ?run_mod.End = null,

    /// Open CPU1's Zig side next to `ours0`, CPU0's Zig-side engine, load
    /// `image` into it when one is given, reset the Zig core from
    /// `vector_base` and hand its registers to `theirs`, CPU1's Unicorn
    /// engine, which stays the caller's.
    pub fn open(self: *Pair, ours0: *engine.Engine, theirs: engine.Engine, image: ?elf.Image, vector_base: u32) !void {
        self.mine = try engine.Engine.open();
        errdefer self.mine.close();
        try self.mine.shareBoardRamWith(ours0);
        if (image) |loaded| _ = try self.mine.loadImage(loaded);
        self.theirs = theirs;
        self.log = .{};
        self.partitions = sau.Sau.init();
        self.regions = mpu.Mpu.init();
        self.lock = .{};
        self.ended = null;
        self.memory = .{
            .memory = .{ .core = &self.mine },
            .log = &self.log,
            .scs = .{ .partitions = &self.partitions, .regions = &self.regions },
        };
        self.cpu = .{ .bus = self.memory.view(), .profile = part.cpu1_profile };
        _ = seed.ppb(self.mine, theirs);
        try self.cpu.reset(vector_base);
        try oracle.load(theirs, snapshot.Snapshot.fromRegs(&self.cpu.regs));
        self.taps = try tap_hook.attach(theirs.handle, &self.log);
    }

    pub fn close(self: *Pair) void {
        tap_hook.detach(self.theirs.handle, self.taps);
        self.lock.deinit(std.heap.page_allocator);
        self.mine.close();
    }

    /// Check up to `instructions` more of CPU1's instructions.
    pub fn turn(self: *Pair, instructions: u64) !void {
        if (self.ended != null) return;
        const end = try self.lock.go(std.heap.page_allocator, &self.cpu, self.theirs, &self.log, instructions);
        if (end != .budget) self.ended = end;
    }
};
