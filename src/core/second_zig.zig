//! CPU1 on the Zig core (RA8EMU-234). The engine CPU1 already has for
//! Unicorn stays as its memory: a second Zig Cpu reads and writes through a
//! BoardBus over that engine, so it reaches the same shared SRAM and the
//! same peripheral blocks as CPU0. The bus names CPU1 as the issuer, so a
//! block that answers per core (IPCSEM, the ICU's per-core view) sees the
//! right one. The SAU, MPU and fault-clear units are CPU1's own, the ones
//! `Second.open` wired for Unicorn.
//!
//! The core carries the M33's profile (src/core/part.zig), so an Armv8.1-M
//! encoding takes UsageFault UNDEFINSTR here, where CPU0 would run it.
//! Its NVIC and decode cache are its own too.
const registry = @import("../periph/registry.zig");
const cpu_mod = @import("cpu/cpu.zig");
const BoardBus = @import("cpu/board_bus.zig").BoardBus;
const NvicSource = @import("cpu/exception/nvic_source.zig").NvicSource;
const DecodeCache = @import("cpu/decode_cache.zig").DecodeCache;
const part = @import("part.zig");
const Second = @import("second_core.zig").Second;

pub const SecondZig = struct {
    board: BoardBus,
    pending: NvicSource = .{},
    decoded: DecodeCache = .{},
    cpu: cpu_mod.Cpu,

    /// CPU1's Zig core over `second`'s engine, reset from its vector table.
    /// Built in storage the caller holds: the core keeps pointers to this
    /// struct's bus, interrupt source and decode cache.
    pub fn open(self: *SecondZig, second: *Second, periph: *registry.Bus) !void {
        self.* = .{
            .board = .{
                .memory = .{ .core = &second.core },
                .periph = periph,
                .issuer = .cpu1,
                .scs = .{ .partitions = &second.partitions, .regions = &second.regions, .clears = &second.clears },
            },
            .cpu = undefined,
        };
        self.cpu = .{ .bus = self.board.view(), .source = self.pending.source(), .profile = part.cpu1_profile };
        self.cpu.decoded = &self.decoded;
        try self.cpu.reset(second.vector_base);
    }

    /// One turn of `instructions`, as the interleave hands them out.
    pub fn turn(self: *SecondZig, instructions: u64) cpu_mod.Stop {
        return self.cpu.run(instructions);
    }
};
