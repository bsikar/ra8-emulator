//! Himax HX6538 (Seeed Grove Vision AI V2) machine description.
//!
//! Models dual Cortex-M55 contexts (`cm55m` 400 MHz + `cm55s` 150 MHz),
//! the pinned SDK/datasheet ITCM/BootROM/DTCM/SRAM0..2/QSPI/PPB memory map
//! and bit-28 aliases, inverted HX bit-28 IDAU polarity, documented SCU,
//! Mailbox, DW APB UART0..2, and Arm CMSDK Timer0..8 blocks, and
//! `.unknown_mmio = .fault`. Runs in loader-established RAM/TCM/XIP fixture
//! mode (no BootROM emulation). Ethos-U55 (`0x4302_0000`, 64 MAC/cycle) is
//! intentionally excluded (`hasNpu() == false`, faulting on MMIO access)
//! until separately qualified against physical Seeed 101021112 hardware.
const core = @import("../../../core/machine/core.zig");
const cpuid = @import("../../../periph/cpuid.zig");
const hx_periph = @import("hx6538.zig");
const Machine = @import("../../../core/machine/machine.zig").Machine;
const memmap = @import("../../../core/memmap.zig");
const memory = @import("../../../core/machine/memory.zig");

pub const regions = [_]memory.Region{
    .{
        .name = "ITCM",
        .base = 0x0000_0000,
        .size = 0x0004_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
        .track_code = true,
    },
    .{
        .name = "BootROM",
        .base = 0x0800_0000,
        .size = 0x0001_0000,
        .perms = .{ .read = true, .write = false, .exec = true },
        .shared = true,
    },
    .{
        .name = "DTCM",
        .base = 0x2000_0000,
        .size = 0x0004_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
        .track_code = true,
    },
    .{
        .name = "SRAM0",
        .base = 0x2400_0000,
        .size = 0x0010_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
        .shared = true,
        .track_code = true,
        .role = .sram,
    },
    .{
        .name = "SRAM1",
        .base = 0x2410_0000,
        .size = 0x0010_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
        .shared = true,
        .track_code = true,
    },
    .{
        .name = "SRAM2",
        .base = 0x2600_0000,
        .size = 0x0006_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
        .shared = true,
        .track_code = true,
    },
    .{
        .name = "QSPI",
        .base = 0x2A00_0000,
        .size = 0x0100_0000,
        .perms = .{ .read = true, .write = false, .exec = true },
        .shared = true,
        .role = .flash,
    },
    .{
        .name = "PPB",
        .base = memmap.ppb_base,
        .size = memmap.ppb_size,
        .perms = .{ .read = true, .write = true, .exec = false },
        .role = .ppb,
    },
};

pub const aliases = [_]memory.Alias{
    .{
        .name = "ITCM_S",
        .view = 0x1000_0000,
        .of = 0x0000_0000,
        .size = 0x0004_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
    },
    .{
        .name = "BootROM_S",
        .view = 0x1800_0000,
        .of = 0x0800_0000,
        .size = 0x0001_0000,
        .perms = .{ .read = true, .write = false, .exec = true },
    },
    .{
        .name = "DTCM_S",
        .view = 0x3000_0000,
        .of = 0x2000_0000,
        .size = 0x0004_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
    },
    .{
        .name = "SRAM0_S",
        .view = 0x3400_0000,
        .of = 0x2400_0000,
        .size = 0x0010_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
    },
    .{
        .name = "SRAM1_S",
        .view = 0x3410_0000,
        .of = 0x2410_0000,
        .size = 0x0010_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
    },
    .{
        .name = "SRAM2_S",
        .view = 0x3600_0000,
        .of = 0x2600_0000,
        .size = 0x0006_0000,
        .perms = .{ .read = true, .write = true, .exec = true },
    },
    .{
        .name = "QSPI_S",
        .view = 0x3A00_0000,
        .of = 0x2A00_0000,
        .size = 0x0100_0000,
        .perms = .{ .read = true, .write = false, .exec = true },
    },
};

pub const mmio = [_]memory.MmioWindow{
    .{ .base = 0x5000_0000, .size = 0x1000_0000, .ns_alias = 0x4000_0000 },
};

pub const memory_map: memory.MemoryMap = .{
    .regions = &regions,
    .aliases = &aliases,
    .mmio = &mmio,
    .unknown_mmio = .fault,
    .idau = .{ .answerFn = hx_periph.idau.callbackFn },
    .attach_ra8_blocks = false,
    .peripheral_set = .hx6538,
    .has_external = false,
    .allow_extra_pages = false,
};

const m55_revision: cpuid.Revision = .{ .variant = 0, .patch = 1 };

const m55_scs: core.scs.ScsConfig = .{
    .irq_lines = hx_periph.irqs.lines,
    .prio_bits = 3,
    .sau_regions = 8,
    .mpu_regions_s = 8,
    .mpu_regions_ns = 8,
    .dwt_comparators = 4,
    .fpb_code = 8,
    .init_vtor = 0x1000_0000,
    .syst_calib = 0,
};

pub const cm55m = core.cortexM55(.{
    .security = true,
    .fpu = .double,
    .mve = true,
    .lob = true,
    .fp16 = true,
    .cache = true,
    .systicks = 2,
    .revision = m55_revision,
    .scs = m55_scs,
});

pub const cm55s = core.cortexM55(.{
    .security = true,
    .fpu = .double,
    .mve = true,
    .lob = true,
    .fp16 = true,
    .cache = true,
    .systicks = 2,
    .revision = m55_revision,
    .scs = m55_scs,
});

pub const machine: Machine = .{
    .name = "hx6538",
    .label = "HX6538",
    .aliases = &.{"grove-vision-ai-v2"},
    .cores = .{ .primary = cm55m, .second = cm55s },
    .memory = &memory_map,
    .part = .ra8d2,
    .npu_enabled = false,
    .peripherals = .hx6538,
    .cpu0_hz = 400_000_000,
    .cpu1_hz = 150_000_000,
    .source = "HX6538-A-DS V01, WE2 SDK WE2_device_addr.h/WE2_ARMCM55.h " ++
        "(loader RAM/TCM mode, no BootROM, U55 @0x43020000 unimplemented; " ++
        "r0p1/r1p1 and FP32/FP64 pending bench read)",
};
