//! Single-core Cortex-M85 RA8E1 MCU machine profile (`R7FA8E1AFDCFB`,
//! FPB-RA8E1 `RTK7FPA8E1S00001BE`), derived from Renesas hardware documentation
//! (`R01UH1129EJ0110` Rev.1.10 & `R20UT5474EG0100` Rev.1.00).
const core = @import("../../../core/machine/core.zig");
pub const fcache = @import("fcache.zig");
const Machine = @import("../../../core/machine/machine.zig").Machine;
const memmap = @import("../../../core/memmap.zig");
const memory = @import("../../../core/machine/memory.zig");
const sau_attr = @import("../../../periph/sau/attribution.zig");

pub const name = "ra8e1";
pub const name_aliases = [_][]const u8{"fpb-ra8e1"};
pub const label = "RA8E1";
pub const source = "RA8E1 HUM R01UH1129EJ0110 Rev.1.10; FPB-RA8E1 UM R20UT5474EG0100 Rev.1.00";

/// 16-byte ASCII part number stored at Factory Flash `PNR0..3` (`0x0300_80F0`).
pub const factory_pnr: *const [16]u8 = "R7FA8E1AFDCFB   ";

/// Hardware address map constants (`R01UH1129EJ0110` Fig. 4.1, Table 4.1, Ch. 6, Ch. 49).
pub const layout = struct {
    pub const itcm_base: u32 = 0x0000_0000;
    pub const itcm_size: u32 = 16 * 1024;
    pub const flash_base: u32 = 0x0200_0000;
    pub const flash_size: u32 = 1024 * 1024;
    pub const factory_base: u32 = 0x0300_80F0;
    pub const factory_size: u32 = 196;
    pub const uidr_offset: u32 = 0x0300_8190 - factory_base;
    pub const mcuver_offset: u32 = 0x0300_81B0 - factory_base;
    pub const code_opt_base: u32 = 0x0300_A100;
    pub const code_opt_size: u32 = 512;
    pub const dtcm_base: u32 = 0x2000_0000;
    pub const dtcm_size: u32 = 16 * 1024;
    pub const sram_base: u32 = 0x2206_0000;
    pub const sram_size: u32 = 512 * 1024;
    pub const standby_sram_base: u32 = 0x2600_0000;
    pub const standby_sram_size: u32 = 1024;
    pub const data_flash_base: u32 = 0x2700_0000;
    pub const data_flash_size: u32 = 12 * 1024;
    pub const data_opt_base: u32 = 0x2703_0050;
    pub const data_opt_size: u32 = 0x2703_0878 - data_opt_base;
    pub const ns_bit: u32 = memmap.ns_offset;
};

/// Canonical Secure regions (`bit[28] = 0`) and Cortex-M85 PPB.
pub const regions = [_]memory.Region{
    .{
        .name = "ITCM",
        .base = layout.itcm_base,
        .size = layout.itcm_size,
        .perms = .{ .read = true, .write = true, .exec = true },
        .shared = false,
        .track_code = true,
    },
    .{
        .name = "FLASH",
        .base = layout.flash_base,
        .size = layout.flash_size,
        .perms = .{ .read = true, .write = false, .exec = true },
        .track_code = true,
        .role = .flash,
    },
    .{
        .name = "FACTORY",
        .base = layout.factory_base,
        .size = layout.factory_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
    .{
        .name = "CODE_OPT",
        .base = layout.code_opt_base,
        .size = layout.code_opt_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
    .{
        .name = "DTCM",
        .base = layout.dtcm_base,
        .size = layout.dtcm_size,
        .perms = .{ .read = true, .write = true, .exec = true },
        .shared = false,
        .track_code = true,
    },
    .{
        .name = "SRAM1",
        .base = layout.sram_base,
        .size = layout.sram_size,
        .perms = .{ .read = true, .write = true, .exec = true },
        .shared = false,
        .track_code = true,
        .role = .sram,
    },
    .{
        .name = "STANDBY_SRAM",
        .base = layout.standby_sram_base,
        .size = layout.standby_sram_size,
        .perms = .{ .read = true, .write = true, .exec = false },
        .shared = false,
    },
    .{
        .name = "DATA_FLASH",
        .base = layout.data_flash_base,
        .size = layout.data_flash_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
    .{
        .name = "DATA_OPT",
        .base = layout.data_opt_base,
        .size = layout.data_opt_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
    .{
        .name = "PPB",
        .base = memmap.ppb_base,
        .size = memmap.ppb_size,
        .perms = .{ .read = true, .write = true, .exec = false },
        .role = .ppb,
    },
};

/// Non-secure bit-28 alias map (`bit[28] = 1`).
pub const aliases = [_]memory.Alias{
    .{
        .name = "NS_ITCM",
        .view = layout.itcm_base + layout.ns_bit,
        .of = layout.itcm_base,
        .size = layout.itcm_size,
    },
    .{
        .name = "NS_FLASH",
        .view = layout.flash_base + layout.ns_bit,
        .of = layout.flash_base,
        .size = layout.flash_size,
        .perms = .{ .read = true, .write = false, .exec = true },
    },
    .{
        .name = "NS_FACTORY",
        .view = layout.factory_base + layout.ns_bit,
        .of = layout.factory_base,
        .size = layout.factory_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
    .{
        .name = "NS_CODE_OPT",
        .view = layout.code_opt_base + layout.ns_bit,
        .of = layout.code_opt_base,
        .size = layout.code_opt_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
    .{
        .name = "NS_DTCM",
        .view = layout.dtcm_base + layout.ns_bit,
        .of = layout.dtcm_base,
        .size = layout.dtcm_size,
    },
    .{
        .name = "NS_SRAM1",
        .view = layout.sram_base + layout.ns_bit,
        .of = layout.sram_base,
        .size = layout.sram_size,
    },
    .{
        .name = "NS_STANDBY_SRAM",
        .view = layout.standby_sram_base + layout.ns_bit,
        .of = layout.standby_sram_base,
        .size = layout.standby_sram_size,
        .perms = .{ .read = true, .write = true, .exec = false },
    },
    .{
        .name = "NS_DATA_FLASH",
        .view = layout.data_flash_base + layout.ns_bit,
        .of = layout.data_flash_base,
        .size = layout.data_flash_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
    .{
        .name = "NS_DATA_OPT",
        .view = layout.data_opt_base + layout.ns_bit,
        .of = layout.data_opt_base,
        .size = layout.data_opt_size,
        .perms = .{ .read = true, .write = false, .exec = false },
    },
};

/// Peripheral MMIO apertures (`R01UH1129EJ0110` Fig. 4.1). Excludes `0x4012_0000..0x401F_FFFF`.
pub const mmio_windows = [_]memory.MmioWindow{
    .{ .base = 0x4000_0000, .size = 0x0010_0000, .ns_alias = 0x5000_0000 },
    .{ .base = 0x4010_0000, .size = 0x0002_0000, .ns_alias = 0x5010_0000 },
    .{ .base = 0x4020_0000, .size = 0x0030_0000, .ns_alias = 0x5020_0000 },
};

/// Hardware fixed IDAU security partition (`R01UH1129EJ0110` Fig. 40.2 & 40.5, pp. 1643-1645).
pub fn idauAnswer(_: ?*const anyopaque, address: u32) sau_attr.Idau {
    return switch (@as(u4, @truncate(address >> 28))) {
        0x0 => .{ .state = .callable, .region = 0 },
        0x1 => .{ .state = .non_secure, .region = 1 },
        0x2 => .{ .state = .callable, .region = 2 },
        0x3 => .{ .state = .non_secure, .region = 3 },
        0x4 => .{ .state = .secure, .region = 4 },
        0x5 => .{ .state = .non_secure, .region = 5 },
        0x6...0xD => .{ .state = .non_secure, .region = 6 },
        0xE, 0xF => .{ .state = .non_secure, .exempt = true, .region = 7 },
    };
}

pub const memory_map: memory.MemoryMap = .{
    .regions = &regions,
    .aliases = &aliases,
    .mmio = &mmio_windows,
    .unknown_mmio = .fault,
    .attach_ra8_blocks = false,
    .peripheral_set = .ra8e1,
    .has_external = false,
    .allow_extra_pages = false,
    .idau = .{ .answerFn = idauAnswer },
};

pub const machine: Machine = .{
    .name = name,
    .aliases = &name_aliases,
    .label = label,
    .cores = .{
        .primary = core.cortexM85(.{
            .security = true,
            .fpu = .double,
            .mve = true,
            .systicks = 2,
            .revision = .{ .variant = 0, .patch = 2 },
            .scs = .{
                .irq_lines = 96,
                .prio_bits = 4,
                .sau_regions = 8,
                .mpu_regions_s = 8,
                .mpu_regions_ns = 8,
                .dwt_comparators = 8,
                .fpb_code = 8,
                .init_vtor = layout.flash_base,
                .syst_calib = 0x0000_270F,
            },
        }),
    },
    .memory = &memory_map,
    .part = .ra8d2,
    .source = source,
};

fn isAllZero(bytes: []const u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}

fn seedIfBlank(guest: anytype, base: u32, defaults: []const u8) !void {
    var probe: [layout.data_opt_size]u8 = undefined;
    const slice = probe[0..defaults.len];
    try guest.read(base, slice);
    if (!isAllZero(slice)) return;
    try guest.program(base, defaults);
}

/// Populate Factory Flash (`PNR0..3` = `"R7FA8E1AFDCFB   "`, `UIDR0..3`, `MCUVER`)
/// and blank Option-Setting Memory defaults when regions are still uninitialized.
pub fn seedMemory(guest: anytype) !void {
    var factory: [layout.factory_size]u8 = @splat(0xFF);
    @memcpy(factory[0..16], factory_pnr);
    const uid = [_]u8{ 0x52, 0x41, 0x38, 0x45, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x46, 0x50, 0x42, 0x01 };
    @memcpy(factory[layout.uidr_offset..][0..16], &uid);
    factory[layout.mcuver_offset] = 0x01;
    try seedIfBlank(guest, layout.factory_base, &factory);

    var code_opt: [layout.code_opt_size]u8 = @splat(0xFF);
    const ofs1_sel_off: usize = 0x0300_A280 - layout.code_opt_base;
    const banksel_sel_off: usize = 0x0300_A290 - layout.code_opt_base;
    const bps_sel_off: usize = 0x0300_A2C0 - layout.code_opt_base;
    @memset(code_opt[ofs1_sel_off..][0..4], 0);
    @memset(code_opt[banksel_sel_off..][0..4], 0);
    @memset(code_opt[bps_sel_off..][0..12], 0);
    try seedIfBlank(guest, layout.code_opt_base, &code_opt);

    var data_opt: [layout.data_opt_size]u8 = @splat(0x00);
    const arc_start: usize = 0x2703_03C0 - layout.data_opt_base;
    @memset(data_opt[0..arc_start], 0xFF);
    try seedIfBlank(guest, layout.data_opt_base, &data_opt);
}
