//! Renesas RA4T1 (`R7FA4T1BB3CFM` / `FPB-RA4T1`) machine profile: sole
//! primary Arm Cortex-M33 (`r0p4`, `CPUID = 0x410FD214`) on RA4T1's flat memory
//! and peripheral map (R01UH0999EJ0140 Rev.1.40 & R20UT5524EG0100 Rev.1.00).
const chip = @import("../../../root.zig");
const pscu = @import("pscu.zig");
const ra4t1 = @import("ra4t1.zig");

const core = chip.core.machine.core;
const machine_mod = chip.core.machine;
const memmap = chip.core.memmap;
const memory = chip.core.machine.memory;

pub const regions = [_]memory.Region{
    .{
        .name = "Code Flash",
        .base = ra4t1.rom_addr.code_flash,
        .size = ra4t1.rom_addr.code_flash_size,
        .perms = .{ .read = true, .write = false, .exec = true },
        .track_code = true,
        .role = .flash,
    },
    .{
        .name = "Factory Flash",
        .base = ra4t1.rom_addr.factory_flash,
        .size = ra4t1.rom_addr.factory_flash_size,
        .perms = .{ .read = true, .write = false, .exec = false },
        .role = .other,
    },
    .{
        .name = "Option Memory",
        .base = ra4t1.rom_addr.option_memory,
        .size = ra4t1.rom_addr.option_memory_size,
        .perms = .{ .read = true, .write = false, .exec = false },
        .role = .other,
    },
    .{
        .name = "Data Flash",
        .base = ra4t1.rom_addr.data_flash,
        .size = ra4t1.rom_addr.data_flash_size,
        .perms = .{ .read = true, .write = false, .exec = false },
        .role = .other,
    },
    .{
        .name = "SRAM0",
        .base = 0x2000_0000,
        .size = 40 * 1024,
        .track_code = true,
        .role = .sram,
    },
    .{
        .name = "PPB",
        .base = memmap.ppb_base,
        .size = memmap.ppb_size,
        .perms = .{ .exec = false },
        .role = .ppb,
    },
};

/// PSBIU (0x4000_0000..0x4007_FFFF), PLBIU (0x4008_0000..0x400F_FFFF),
/// PHBIU (0x4010_0000..0x4017_FFFF), and FLBIU (0x407E_0000..0x407F_FFFF),
/// with NO 0x5000_0000 Non-secure alias window (R01UH0999EJ0140 Table 13.2).
pub const mmio = [_]memory.MmioWindow{
    .{ .base = 0x4000_0000, .size = 0x0018_0000 },
    .{ .base = 0x407E_0000, .size = 0x0002_0000 },
};

pub const memory_map: memory.MemoryMap = .{
    .regions = &regions,
    .aliases = &.{},
    .mmio = &mmio,
    .unknown_mmio = .shadow_alternating,
    .attach_ra8_blocks = false,
    .peripheral_set = .ra4t1,
    .has_external = false,
    .allow_extra_pages = false,
    .idau = pscu.Pscu.resetCallback(),
};

pub const primary_core: core.Core = core.cortexM33(.{
    .security = true,
    .fpu = .single,
    .systicks = 2,
    .revision = .{ .variant = 0, .patch = 4 },
    .scs = .{
        .irq_lines = 98,
        .prio_bits = 4,
        .sau_regions = 0,
        .mpu_regions_s = 8,
        .mpu_regions_ns = 8,
        .dwt_comparators = 4,
        .fpb_code = 8,
        .init_vtor = 0x0000_0000,
        .syst_calib = 0x4000_0147,
    },
});

pub const machine: machine_mod.Machine = .{
    .name = "ra4t1",
    .label = "RA4T1",
    .aliases = &.{"fpb-ra4t1"},
    .cores = .{ .primary = primary_core },
    .memory = &memory_map,
    .part = .ra8d2,
    .source = "R01UH0999EJ0140 Rev.1.40; R20UT5524EG0100 Rev.1.00",
};
