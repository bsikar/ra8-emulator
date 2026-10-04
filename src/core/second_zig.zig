//! CPU1 on the Zig core (RA8EMU-234). Its memory is a memory.Guest
//! (RA8EMU-535): the engine CPU1 already has for Unicorn, which shares
//! CPU0's SRAM, or a Store with no engine at all (RA8EMU-572). A second Zig Cpu reads and writes through a BoardBus
//! over that Guest, so it reaches the same shared SRAM and the same
//! peripheral blocks as CPU0. The bus names CPU1 as the issuer, so a
//! block that answers per core (IPCSEM, the ICU's per-core view) sees the
//! right one. The SAU, MPU and fault-clear units are CPU1's own, the ones
//! `Second.open` wired for Unicorn.
//!
//! The core carries the M33's profile (src/core/part.zig), so an Armv8.1-M
//! encoding takes UsageFault UNDEFINSTR here, where CPU0 would run it.
//! Its NVIC, decode cache and block cache are its own too, and it polls
//! the NVIC through its own quiet source, as CPU0 does (RA8EMU-440).
const std = @import("std");
const registry = @import("../periph/registry.zig");
const cpu_mod = @import("cpu/cpu.zig");
const BoardBus = @import("cpu/board_bus.zig").BoardBus;
const Guest = @import("cpu/memory/guest.zig").Guest;
const GuestBus = @import("cpu/memory/guest_bus.zig").GuestBus;
const mpu_check = @import("cpu/mpu_check.zig");
const NvicSource = @import("cpu/exception/nvic_source.zig").NvicSource;
const QuietSource = @import("cpu/exception/quiet_source.zig").QuietSource;
const DecodeCache = @import("cpu/decode_cache.zig").DecodeCache;
const BlockCache = @import("cpu/block_cache.zig").BlockCache;
const code_lines = @import("cpu/code_lines.zig");
const part = @import("part.zig");
const Second = @import("second_core.zig").Second;
const sau = @import("../periph/sau.zig");
const mpu = @import("../periph/mpu/mpu.zig");
const fault_clear = @import("../periph/fault_clear.zig");

/// What CPU1's Zig core reads from outside its memory: its own SAU, MPU
/// table and fault clears, and the table it resets from.
pub const Units = struct {
    partitions: *sau.Sau,
    regions: *mpu.Mpu,
    clears: *fault_clear.Clears,
    vector_base: u32,

    pub fn of(second: *Second) Units {
        return .{ .partitions = &second.partitions, .regions = &second.regions, .clears = &second.clears, .vector_base = second.vector_base };
    }
};

pub const SecondZig = struct {
    /// CPU1's memory. The board bus points into it, so it lives here.
    memory: Guest,
    board: BoardBus,
    pending: NvicSource = .{},
    quiet: QuietSource = undefined,
    decoded: DecodeCache = .{},
    cpu: cpu_mod.Cpu,
    check: mpu_check.Check = undefined,
    /// CPU1's formed blocks, when the run uses them (RA8EMU-408).
    formed: ?*BlockCache = null,

    /// CPU1's Zig core over `second`'s memory, reset from its vector table.
    /// Built in storage the caller holds: the core keeps pointers to this
    /// struct's bus, quiet source, interrupt source and decode cache.
    pub fn open(self: *SecondZig, second: *Second, periph: *registry.Bus) !void {
        try self.openOn(.{ .engine = second.core }, Units.of(second), periph);
    }

    /// The same core over any `memory`, a Store included, so CPU1 runs with
    /// no engine open (RA8EMU-572).
    pub fn openOn(self: *SecondZig, memory: Guest, units: Units, periph: *registry.Bus) !void {
        self.* = .{ .memory = memory, .board = undefined, .cpu = undefined };
        self.board = .{
            .memory = GuestBus.of(&self.memory, false),
            .periph = periph,
            .issuer = .cpu1,
            .scs = .{ .partitions = units.partitions, .regions = units.regions, .clears = units.clears },
        };
        self.quiet = .{ .inner = self.pending.source(), .memory = self.board.view() };
        self.cpu = .{ .bus = self.quiet.bus(), .source = self.quiet.source(), .quiet = &self.quiet, .profile = part.cpu1_profile };
        self.cpu.decoded = &self.decoded;
        self.board.security = &self.cpu.banked;
        self.pending.banked = &self.cpu.banked;
        self.check = .{ .unit = units.regions };
        self.board.check = &self.check;
        self.cpu.mpu = &self.check;
        try self.cpu.reset(units.vector_base);
    }

    /// Run from formed blocks, as CPU0 does by default. The cache watches
    /// every write, so CPU0's stores over CPU1's code drop its blocks.
    pub fn useBlocks(self: *SecondZig) !void {
        const cache = try std.heap.page_allocator.create(BlockCache);
        errdefer std.heap.page_allocator.destroy(cache);
        cache.init();
        try code_lines.watch(&cache.lines);
        self.formed = cache;
        self.cpu.blocks = cache;
    }

    pub fn dropBlocks(self: *SecondZig) void {
        const cache = self.formed orelse return;
        code_lines.unwatch(&cache.lines);
        self.cpu.blocks = null;
        self.formed = null;
        std.heap.page_allocator.destroy(cache);
    }

    /// One turn of `instructions`, as the interleave hands them out.
    pub fn turn(self: *SecondZig, instructions: u64) cpu_mod.Stop {
        return self.cpu.run(instructions);
    }
};
