//! Manufacturer-sourced per-board and per-probe hardware profiles, memory
//! windows, runtime licensing rules, and bench qualification state.
//! Physical qualification never claims emulation coverage, and absent boards
//! remain explicitly unverified rather than inferred from datasheets.
const std = @import("std");

pub const Availability = enum {
    arrived_qualified,
    unavailable_on_bench,
    unpurchased_unavailable,
};

pub const CapabilityStatus = enum {
    qualified,
    unsupported,
    pending_hardware,
};

pub const CapabilityMatrix = struct {
    build: CapabilityStatus,
    flash_verify: CapabilityStatus,
    halt_read_step: CapabilityStatus,
    reset_run: CapabilityStatus,
    uart: CapabilityStatus,
};

pub const FlashWindow = struct {
    base: u32,
    size: u32,
    option_setting_base: u32 = 0,
};

pub const PartReadback = struct {
    address: u32,
    words: u8,
    expected_ascii: []const u8,
};

pub const SwdIdentity = struct {
    jlink_device: []const u8,
    sw_dp_idcode: u32,
    cpuid: u32,
    part_readback: ?PartReadback = null,
};

pub const Profile = struct {
    id: []const u8,
    board_name: []const u8,
    orderable_part: []const u8,
    board_revision: []const u8,
    mcu_part: []const u8,
    core_topology: []const u8,
    memory_summary: []const u8,
    flash_window: ?FlashWindow,
    compiler_sdk: []const u8,
    probe_transport: []const u8,
    probe_usb_id: []const u8,
    runtime_redistribution: []const u8,
    reset_behavior: []const u8,
    uart_behavior: []const u8,
    uart_wired: bool,
    swd: ?SwdIdentity,
    availability: Availability,
    emulation_claimed: bool = false,
    capabilities: CapabilityMatrix,
    sources: []const []const u8,
};

pub const all = [_]Profile{
    .{
        .id = "fpb-ra8e1",
        .board_name = "FPB-RA8E1",
        .orderable_part = "RTK7FPA8E1S00001BE",
        .board_revision = "v1.00",
        .mcu_part = "R7FA8E1AFDCFB",
        .core_topology = "single Arm Cortex-M85 r0p2 (Armv8.1-M, MVE, TrustZone)",
        .memory_summary = "1 MiB Code Flash @ 0x02000000, 12 KiB Data Flash @ 0x27000000, " ++
            "64 KiB ITCM @ 0x00000000, 64 KiB DTCM @ 0x20000000, 32 KiB SRAM0 @ 0x22000000, " ++
            "512 KiB SRAM1 @ 0x22060000; Option Flash @ 0x0300A100 fenced",
        .flash_window = .{
            .base = 0x0200_0000,
            .size = 0x0010_0000,
            .option_setting_base = 0x0300_A100,
        },
        .compiler_sdk = "Zig 0.17.0 (thumb-freestanding-eabi -mcpu=cortex_m85) or Arm GNU 14.2; " ++
            "project-pinned linker script and startup",
        .probe_transport = "onboard SEGGER J-Link OB-RA4M2 over SWD (jlink-usb)",
        .probe_usb_id = "1366:0105",
        .runtime_redistribution = "requires user-installed SEGGER J-Link Software V8.18+; " ++
            "proprietary runtime is never redistributed; OpenOCD/pyOCD not assumed",
        .reset_behavior = "SWD reset and run via J-Link Commander (r/g)",
        .uart_behavior = "onboard J-Link CDC VCOM wired to SCI9_B (P101 RXD9_A, P102 TXD9_A) at 115200 8N1",
        .uart_wired = true,
        .swd = .{
            .jlink_device = "R7FA8E1AF",
            .sw_dp_idcode = 0x6BA0_2477,
            .cpuid = 0x410F_D232,
            .part_readback = .{
                .address = 0x0300_80F0,
                .words = 4,
                .expected_ascii = "R7FA8E1AFDCFB",
            },
        },
        .availability = .arrived_qualified,
        .capabilities = .{
            .build = .qualified,
            .flash_verify = .qualified,
            .halt_read_step = .qualified,
            .reset_run = .qualified,
            .uart = .qualified,
        },
        .sources = &.{
            "Renesas R20UT5474EG0100 Rev.1.00 (FPB-RA8E1 v1 User's Manual)",
            "Renesas R01UH1129EJ0110 Rev.1.10 (RA8E1 Group User's Manual: Hardware)",
            "https://www.renesas.com/en/design-resources/boards-kits/fpb-ra8e1",
        },
    },
    .{
        .id = "fpb-ra4t1",
        .board_name = "FPB-RA4T1",
        .orderable_part = "RTK7FPA4T1S00001BE",
        .board_revision = "v1.00",
        .mcu_part = "R7FA4T1BB3CFM",
        .core_topology = "single Arm Cortex-M33 r0p4 (Armv8-M Mainline, DSP, FPU, TrustZone)",
        .memory_summary = "256 KiB Code Flash @ 0x00000000, 4 KiB Data Flash @ 0x08000000, " ++
            "40 KiB SRAM0 @ 0x20000000; Option Flash @ 0x0100A100 fenced",
        .flash_window = .{
            .base = 0x0000_0000,
            .size = 0x0004_0000,
            .option_setting_base = 0x0100_A100,
        },
        .compiler_sdk = "Zig 0.17.0 (thumb-freestanding-eabi -mcpu=cortex_m33) or Arm GNU 14.2; " ++
            "project-pinned linker script and startup",
        .probe_transport = "onboard SEGGER J-Link OB-RA4M2 over SWD (jlink-usb)",
        .probe_usb_id = "1366:0105",
        .runtime_redistribution = "requires user-installed SEGGER J-Link Software V8.18+; " ++
            "proprietary runtime is never redistributed; OpenOCD/pyOCD not assumed",
        .reset_behavior = "SWD reset and run via J-Link Commander (r/g)",
        .uart_behavior = "onboard J-Link OB enumerates USB CDC but FPB-RA4T1 v1 PCB leaves VCOM RX/TX " ++
            "unrouted to RA4T1 pins (E33 routes P109/TDO SWO only); probe VCOM UART unsupported",
        .uart_wired = false,
        .swd = .{
            .jlink_device = "R7FA4T1BB",
            .sw_dp_idcode = 0x6BA0_2477,
            .cpuid = 0x410F_D214,
            .part_readback = .{
                .address = 0x0100_80F0,
                .words = 4,
                .expected_ascii = "R7FA4T1BB3CFM",
            },
        },
        .availability = .arrived_qualified,
        .capabilities = .{
            .build = .qualified,
            .flash_verify = .qualified,
            .halt_read_step = .qualified,
            .reset_run = .qualified,
            .uart = .unsupported,
        },
        .sources = &.{
            "Renesas R20UT5524EG0100 Rev.1.00 (FPB-RA4T1 v1 User's Manual, Fig. 4 & Table 3)",
            "Renesas R01UH0999EJ0140 Rev.1.40 (RA4T1 Group User's Manual: Hardware)",
            "https://www.renesas.com/en/design-resources/boards-kits/fpb-ra4t1",
        },
    },
    .{
        .id = "ra8d2",
        .board_name = "EK-RA8D2",
        .orderable_part = "RTK7EKA8D2S00001BE",
        .board_revision = "v1",
        .mcu_part = "R7KA8D2KFLCAC",
        .core_topology = "dual Arm Cortex-M85 r1p1 (CPU0, up to 1 GHz, MVE-F) + " ++
            "Arm Cortex-M33 r0p4 (CPU1, up to 250 MHz); no Ethos-U55 NPU",
        .memory_summary = "1 MiB Code MRAM @ 0x02000000, 2 MiB total SRAM " ++
            "(256 KiB M85 TCM + 128 KiB M33 TCM + 1664 KiB user SRAM)",
        .flash_window = .{ .base = 0x0200_0000, .size = 0x0010_0000 },
        .compiler_sdk = "Zig 0.17.0 or Arm GNU 14.2; project-pinned dual-core startup, linker, and BSP/FSP",
        .probe_transport = "onboard SEGGER J-Link OB or external SWD probe (pending physical bench)",
        .probe_usb_id = "1366:0105",
        .runtime_redistribution = "requires user-installed SEGGER J-Link Software; not redistributed",
        .reset_behavior = "unverified on this bench; blocked on physical board attachment",
        .uart_behavior = "unverified on this bench; blocked on physical board attachment",
        .uart_wired = false,
        .swd = null,
        .availability = .unavailable_on_bench,
        .capabilities = .{
            .build = .qualified,
            .flash_verify = .pending_hardware,
            .halt_read_step = .pending_hardware,
            .reset_run = .pending_hardware,
            .uart = .pending_hardware,
        },
        .sources = &.{
            "Renesas R01DS0493EJ0130 Rev.1.30 (RA8D2 Group Datasheet)",
            "Renesas R01UH1065EJ0130 (RA8D2 Group User's Manual: Hardware)",
            "https://www.renesas.com/en/design-resources/boards-kits/ek-ra8d2",
        },
    },
    .{
        .id = "grove-vision-ai-v2",
        .board_name = "Grove Vision AI Module V2",
        .orderable_part = "101021112",
        .board_revision = "V2",
        .mcu_part = "HX6538",
        .core_topology = "dual Arm Cortex-M55 (big + little, Helium/MVE) + Arm Ethos-U55 NPU",
        .memory_summary = "external QSPI flash via Himax WE2 image container + on-chip SRAM/TCM",
        .flash_window = null,
        .compiler_sdk = "Arm GNU Toolchain + make + pinned HimaxWiseEyePlus SDK + we2 image generator + " ++
            "Ethos-U55 Vela compiler (not provisioned by Zig baseline)",
        .probe_transport = "USB-C CH343 serial XMODEM bootloader only by default; " ++
            "bootloader deployment is not SWD hardware debugging",
        .probe_usb_id = "1a86:55d3",
        .runtime_redistribution = "vendor serial/image/NPU tools are user-supplied; " ++
            "SWD debug requires external probe pad wiring and validated target support",
        .reset_behavior = "unverified on this bench; serial bootloader reset is not SWD reset/halt proof",
        .uart_behavior = "unverified on this bench; CH343 USB-UART pending physical module attachment",
        .uart_wired = false,
        .swd = null,
        .availability = .unavailable_on_bench,
        .capabilities = .{
            .build = .pending_hardware,
            .flash_verify = .pending_hardware,
            .halt_read_step = .pending_hardware,
            .reset_run = .pending_hardware,
            .uart = .pending_hardware,
        },
        .sources = &.{
            "https://wiki.seeedstudio.com/grove_vision_ai_v2/",
            "https://github.com/HimaxWiseEyePlus/Seeed_Grove_Vision_AI_Module_V2",
        },
    },
    .{
        .id = "ra8p1",
        .board_name = "RA8P1 reference target",
        .orderable_part = "unpurchased",
        .board_revision = "n/a",
        .mcu_part = "R7KA8P1KFLCAC",
        .core_topology = "dual Arm Cortex-M85 r1p1 (CPU0, up to 1 GHz) + " ++
            "Arm Cortex-M33 r0p4 (CPU1, up to 250 MHz) + Arm Ethos-U55 NPU r2p0_01eac0 (256 MACs)",
        .memory_summary = "up to 1 MiB Code MRAM @ 0x02000000, 2 MiB total SRAM " ++
            "(256 KiB M85 TCM + 128 KiB M33 TCM + 1664 KiB user SRAM)",
        .flash_window = .{ .base = 0x0200_0000, .size = 0x0010_0000 },
        .compiler_sdk = "Zig 0.17.0 or Arm GNU 14.2 + Ethos-U55 model compiler/runtime (unprovisioned)",
        .probe_transport = "unpurchased hardware; no physical probe profile bound",
        .probe_usb_id = "",
        .runtime_redistribution = "unavailable hardware; does not block arrived boards",
        .reset_behavior = "unavailable hardware (unpurchased)",
        .uart_behavior = "unavailable hardware (unpurchased)",
        .uart_wired = false,
        .swd = null,
        .availability = .unpurchased_unavailable,
        .capabilities = .{
            .build = .qualified,
            .flash_verify = .pending_hardware,
            .halt_read_step = .pending_hardware,
            .reset_run = .pending_hardware,
            .uart = .pending_hardware,
        },
        .sources = &.{
            "Renesas R01DS0439EJ0130 Rev.1.30 (RA8P1 Group Datasheet)",
            "https://www.renesas.com/en/products/ra8p1",
        },
    },
};

pub fn find(id: []const u8) !Profile {
    for (all) |profile| {
        if (std.mem.eql(u8, profile.id, id)) return profile;
    }
    return error.UnknownBoardProfile;
}
