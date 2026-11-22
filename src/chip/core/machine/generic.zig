//! Vendor-neutral single-core Cortex-M33, Cortex-M55, and Cortex-M85 machine
//! definitions.
//!
//! Provides a minimal machine with one core, its architectural System Control
//! Space (SCS/PPB), one executable read-only flash region holding the vector
//! table, and one SRAM region, with configurable bases and capacities and no
//! vendor peripherals attached. Serves both as a selectable standalone target
//! (`--part cortex-m33`, `--part cortex-m55`, `--part cortex-m85`) and as a
//! starting template for MCU profiles.
const core = @import("core.zig");
const cpuid = @import("../../periph/cpuid.zig");
const Machine = @import("machine.zig").Machine;
const memmap = @import("../memmap.zig");
const memory = @import("memory.zig");

const default_source = "Armv8-M Architecture Reference Manual";

pub const Layout = struct {
    flash_base: u32 = 0x0000_0000,
    flash_size: u32 = 256 * 1024,
    sram_base: u32 = 0x2000_0000,
    sram_size: u32 = 64 * 1024,
};

pub fn regionsFor(comptime layout: Layout) [3]memory.Region {
    return .{
        .{
            .name = "FLASH",
            .base = layout.flash_base,
            .size = layout.flash_size,
            .perms = .{ .read = true, .write = false, .exec = true },
            .track_code = true,
            .role = .flash,
        },
        .{
            .name = "SRAM",
            .base = layout.sram_base,
            .size = layout.sram_size,
            .perms = .{ .read = true, .write = true, .exec = true },
            .shared = false,
            .track_code = true,
            .role = .sram,
        },
        .{
            .name = "PPB",
            .base = memmap.ppb_base,
            .size = memmap.ppb_size,
            .perms = .{ .read = true, .write = true, .exec = false },
            .role = .ppb,
        },
    };
}

fn MapHolder(comptime layout: Layout) type {
    return struct {
        const regions = regionsFor(layout);
        const map: memory.MemoryMap = .{
            .regions = &regions,
            .aliases = &.{},
            .mmio = &.{},
            .unknown_mmio = .fault,
            .attach_ra8_blocks = false,
            .has_external = false,
            .allow_extra_pages = false,
        };
    };
}

pub fn memoryMap(comptime layout: Layout) *const memory.MemoryMap {
    return &MapHolder(layout).map;
}

pub const M33Config = struct {
    name: []const u8 = "cortex-m33",
    label: []const u8 = "Cortex-M33",
    layout: Layout = .{},
    security: bool = false,
    fpu: core.Fpu = .single,
    systicks: u2 = 1,
    revision: cpuid.Revision = .{},
    scs: core.scs.ScsConfig = .{
        .irq_lines = 32,
        .prio_bits = 4,
        .sau_regions = 0,
        .mpu_regions_s = 8,
        .mpu_regions_ns = 0,
        .dwt_comparators = 4,
        .fpb_code = 8,
    },
    source: []const u8 = default_source,
};

pub const M55Config = struct {
    name: []const u8 = "cortex-m55",
    label: []const u8 = "Cortex-M55",
    layout: Layout = .{},
    security: bool = false,
    fpu: core.Fpu = .double,
    mve: bool = true,
    lob: bool = true,
    fp16: bool = true,
    cache: bool = true,
    systicks: u2 = 1,
    revision: cpuid.Revision = .{ .variant = 1, .patch = 1 },
    scs: core.scs.ScsConfig = .{
        .irq_lines = 32,
        .prio_bits = 4,
        .sau_regions = 0,
        .mpu_regions_s = 8,
        .mpu_regions_ns = 0,
        .dwt_comparators = 4,
        .fpb_code = 8,
    },
    source: []const u8 = default_source,
};

pub const M85Config = struct {
    name: []const u8 = "cortex-m85",
    label: []const u8 = "Cortex-M85",
    layout: Layout = .{},
    security: bool = false,
    fpu: core.Fpu = .double,
    mve: bool = true,
    systicks: u2 = 1,
    revision: cpuid.Revision = .{},
    scs: core.scs.ScsConfig = .{
        .irq_lines = 32,
        .prio_bits = 4,
        .sau_regions = 0,
        .mpu_regions_s = 8,
        .mpu_regions_ns = 0,
        .dwt_comparators = 8,
        .fpb_code = 8,
    },
    source: []const u8 = default_source,
};

fn resolvedScs(scs_cfg: core.scs.ScsConfig, flash_base: u32) core.scs.ScsConfig {
    var out = scs_cfg;
    if (out.init_vtor == null) out.init_vtor = flash_base;
    return out;
}

pub fn cortexM33Machine(comptime cfg: M33Config) Machine {
    return .{
        .name = cfg.name,
        .label = cfg.label,
        .cores = .{
            .primary = core.cortexM33(.{
                .security = cfg.security,
                .fpu = cfg.fpu,
                .systicks = cfg.systicks,
                .revision = cfg.revision,
                .scs = resolvedScs(cfg.scs, cfg.layout.flash_base),
            }),
        },
        .memory = memoryMap(cfg.layout),
        .part = .ra8d2,
        .source = cfg.source,
    };
}

pub fn cortexM55Machine(comptime cfg: M55Config) Machine {
    return .{
        .name = cfg.name,
        .label = cfg.label,
        .cores = .{
            .primary = core.cortexM55(.{
                .security = cfg.security,
                .fpu = cfg.fpu,
                .mve = cfg.mve,
                .lob = cfg.lob,
                .fp16 = cfg.fp16,
                .cache = cfg.cache,
                .systicks = cfg.systicks,
                .revision = cfg.revision,
                .scs = resolvedScs(cfg.scs, cfg.layout.flash_base),
            }),
        },
        .memory = memoryMap(cfg.layout),
        .part = .ra8d2,
        .source = cfg.source,
    };
}

pub fn cortexM85Machine(comptime cfg: M85Config) Machine {
    return .{
        .name = cfg.name,
        .label = cfg.label,
        .cores = .{
            .primary = core.cortexM85(.{
                .security = cfg.security,
                .fpu = cfg.fpu,
                .mve = cfg.mve,
                .systicks = cfg.systicks,
                .revision = cfg.revision,
                .scs = resolvedScs(cfg.scs, cfg.layout.flash_base),
            }),
        },
        .memory = memoryMap(cfg.layout),
        .part = .ra8d2,
        .source = cfg.source,
    };
}

pub const cortex_m33: Machine = cortexM33Machine(.{});
pub const cortex_m55: Machine = cortexM55Machine(.{});
pub const cortex_m85: Machine = cortexM85Machine(.{});
