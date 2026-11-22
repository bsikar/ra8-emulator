//! CPU1 on the Zig core (RA8EMU-234). Its memory is a memory.Guest
//! (RA8EMU-535) over CPU1's own Store, which borrows CPU0's SRAM
//! (RA8EMU-572). A second Zig Cpu reads and writes through a BoardBus
//! over that Guest, so it reaches the same shared SRAM and the same
//! peripheral blocks as CPU0. The bus names CPU1 as the issuer, so a
//! block that answers per core (IPCSEM, the ICU's per-core view) sees the
//! right one. The SAU, MPU and fault-clear units are CPU1's own.
//!
//! The core carries the M33's profile (src/chip/core/part/part.zig), so an Armv8.1-M
//! encoding takes UsageFault UNDEFINSTR here, where CPU0 would run it.
//! Its NVIC, decode cache and block cache are its own too, and it polls
//! the NVIC through its own quiet source, as CPU0 does (RA8EMU-440).
const std = @import("std");

const BlockCache = @import("../../cpu/block/cache.zig").BlockCache;
const BoardBus = @import("../../cpu/board_bus.zig").BoardBus;
const cpu_mod = @import("../../cpu/cpu.zig");
const DecodeCache = @import("../../cpu/decode/cache.zig").DecodeCache;
const fault_clear = @import("../../../periph/fault/clear.zig");
const Guest = @import("../../cpu/memory/guest/guest.zig").Guest;
const GuestBus = @import("../../cpu/memory/guest/bus.zig").GuestBus;
const loaded_image = @import("../../loaded_image.zig");
const mpu = @import("../../../periph/mpu/mpu.zig");
const mpu_check = @import("../../cpu/mpu_check.zig");
const mpu_guard = @import("../../mpu_guard.zig");
const NvicSource = @import("../../cpu/exception/nvic_source.zig").NvicSource;
const part = @import("../../part/part.zig");
const profile = @import("../../cpu/profile.zig");
const QuietSource = @import("../../cpu/exception/quiet_source.zig").QuietSource;
const registry = @import("../../../periph/registry.zig");
pub const run = @import("run.zig");
const sau = @import("../../../periph/sau/sau.zig");
const scb = @import("../../../periph/scb/scb.zig");
const scs_mod = @import("../../machine/scs.zig");
const Second = @import("../core.zig").Second;
const second_core = @import("../core.zig");
const Store = @import("../../cpu/memory/store.zig").Store;
const topology = @import("../../machine/topology.zig");
const Wiring = @import("../wiring.zig").Wiring;

/// What CPU1's Zig core reads from outside its memory: its own SAU, MPU
/// table and fault clears, and the table it resets from.
pub const Units = struct {
    partitions: *sau.Sau,
    regions: *mpu.Mpu,
    clears: *fault_clear.Clears,
    vector_base: u32,
    profile: profile.Profile = part.cpu1_profile,
    security: bool = true,
    systicks: u2 = 2,
    scs: scs_mod.ScsConfig = .{},
    dwt_numcomp: ?u4 = null,

    pub fn of(second: *Second) Units {
        return .{
            .partitions = &second.partitions,
            .regions = &second.regions,
            .clears = &second.clears,
            .vector_base = second.state.vector_base,
        };
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

    /// CPU1's Zig core over `memory` (its own store), reset from its vector
    /// table, so CPU1 runs with no engine open (RA8EMU-572). Built in storage
    /// the caller holds: the core keeps pointers to this struct's bus, quiet
    /// source, interrupt source and decode cache.
    pub fn openOn(self: *SecondZig, memory: Guest, units: Units, periph: *registry.Bus) !void {
        self.* = .{ .memory = memory, .board = undefined, .cpu = undefined };
        self.board = .{
            .memory = GuestBus.of(&self.memory, false),
            .periph = periph,
            .issuer = .cpu1,
            .scs = .{
                .partitions = if (units.security) units.partitions else null,
                .regions = units.regions,
                .clears = units.clears,
                .config = units.scs,
                .systicks = units.systicks,
                .has_security = units.security,
                .dwt_numcomp = units.dwt_numcomp,
                .fpb_wired = true,
                .id = units.profile.idBank(units.security, units.scs.fpb_code),
            },
        };
        self.pending = .{ .model = .{
            .irq_lines = units.scs.irq_lines,
            .prio_bits = units.scs.prio_bits,
            .systicks = units.systicks,
        } };
        self.quiet = .{ .inner = self.pending.source(), .memory = self.board.view() };
        self.cpu = .{
            .bus = self.quiet.bus(),
            .source = self.quiet.source(),
            .quiet = &self.quiet,
            .profile = units.profile,
        };
        self.cpu.decoded = &self.decoded;
        self.board.security = if (units.security) &self.cpu.banked else null;
        // CPACR reaches CPU1's own FP state (RA8EMU-950).
        self.board.scs.attachFp(&self.cpu.fp, units.profile.fpu != .none or units.profile.mve);
        self.pending.banked = &self.cpu.banked;
        self.pending.clear_due = &self.quiet.clear_due;
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
        try self.memory.store.fanMut().attach(&cache.lines);
        self.formed = cache;
        self.cpu.blocks = cache;
    }

    pub fn dropBlocks(self: *SecondZig) void {
        const cache = self.formed orelse return;
        self.memory.store.fanMut().detach(&cache.lines);
        self.cpu.blocks = null;
        self.formed = null;
        std.heap.page_allocator.destroy(cache);
    }

    /// One turn of `instructions`, as the interleave hands them out.
    pub fn turn(self: *SecondZig, instructions: u64) cpu_mod.Stop {
        return self.cpu.run(instructions);
    }
};

/// CPU1 with memory of its own (RA8EMU-574): a Store that borrows CPU0's
/// shared regions from `lender`, and its own SAU, MPU table, guard, AIRCR
/// model and fault clears, so it comes up with no engine open. Built in
/// storage the caller holds: the core keeps pointers into it.
pub const Own = struct {
    store: Store,
    partitions: sau.Sau = sau.Sau.init(),
    regions: mpu.Mpu = mpu.Mpu.init(),
    guard: mpu_guard.Guard = mpu_guard.Guard.init(),
    control: scb.Scb = scb.Scb.init(),
    clears: fault_clear.Clears = fault_clear.Clears.init(),
    core: SecondZig = undefined,

    /// Prime CPU1's PPB windows as an M33, load `image`, and reset the core
    /// from the image's vector table.
    pub fn open(self: *Own, lender: *Store, wiring: Wiring, image: loaded_image.Image) !void {
        self.* = .{ .store = try Store.init(lender) };
        errdefer self.store.deinit();
        _ = try bringUp(&self.core, .{ .store = &self.store, .initiator = .cpu1 }, wiring, .{
            .partitions = &self.partitions,
            .regions = &self.regions,
            .guard = &self.guard,
            .control = &self.control,
            .clears = &self.clears,
        }, image);
    }

    pub fn close(self: *Own) void {
        self.core.dropBlocks();
        self.store.deinit();
    }
};

/// The units a Zig CPU1 keeps outside its memory, wherever they are held.
pub const Parts = struct {
    partitions: *sau.Sau,
    regions: *mpu.Mpu,
    guard: *mpu_guard.Guard,
    control: *scb.Scb,
    clears: *fault_clear.Clears,
};

/// Prime CPU1's PPB windows into `memory` as an M33, load `image` there,
/// and open `core` over it reset from the image's vector table
/// (RA8EMU-574, shared with the run path by RA8EMU-588).
pub fn bringUp(
    core: *SecondZig,
    memory: Guest,
    wiring: Wiring,
    parts: Parts,
    image: loaded_image.Image,
) !second_core.Seeded {
    const desc = wiring.core orelse return topology.Error.AbsentCore;
    const setup = memory.asInitiator(.none);
    try wiring.prime(setup, .{
        .partitions = parts.partitions,
        .regions = parts.regions,
        .guard = parts.guard,
        .identity = desc.cpuid,
        .security = desc.security,
        .systicks = desc.systicks,
        .scs = desc.scs,
        .control = parts.control,
        .clears = parts.clears,
    });
    const seeded = try second_core.seedImage(setup, image);
    const units: Units = .{
        .partitions = parts.partitions,
        .regions = parts.regions,
        .clears = parts.clears,
        .vector_base = seeded.vector_base,
        .profile = desc.profile,
        .security = desc.security,
        .systicks = desc.systicks,
        .scs = desc.scs,
        .dwt_numcomp = desc.dwtComparators(),
    };
    try core.openOn(memory, units, wiring.bus);
    return seeded;
}
