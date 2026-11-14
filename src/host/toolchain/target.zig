//! Tool requirements are independent of board or silicon implementation coverage.
const std = @import("std");
pub const Target = struct {
    id: []const u8,
    board: []const u8,
    sdk: []const u8,
    probe: []const u8,
    image_tools: []const u8,
    npu_tools: []const u8,
    reference: []const u8,
};
pub const targets = [_]Target{
    .{ .id = "ra8d2", .board = "EK-RA8D2", .sdk = "project-pinned startup, linker script and BSP/FSP dependencies", .probe = "explicit target-supported debug-probe server and host USB driver/permissions", .image_tools = "project-specific ELF/flash image recipe", .npu_tools = "not applicable", .reference = "https://www.renesas.com/en/design-resources/boards-kits/ek-ra8d2" },
    .{ .id = "ra8p1", .board = "exact board/part must be selected by the project", .sdk = "project-pinned RA8P1 startup, linker script and BSP/FSP dependencies", .probe = "explicit target-supported debug-probe server and host USB driver/permissions", .image_tools = "project-specific ELF/flash image recipe", .npu_tools = "matching Ethos-U55 model compiler/runtime and model artifacts; not provisioned", .reference = "https://www.renesas.com/en/products/ra8p1" },
    .{ .id = "fpb-ra8e1", .board = "RTK7FPA8E1S00001BE", .sdk = "project-pinned FPB-RA8E1 startup, linker script and BSP/FSP dependencies", .probe = "onboard J-Link; separately licensed user installation and USB access", .image_tools = "project-specific ELF/flash image recipe", .npu_tools = "not applicable", .reference = "https://www.renesas.com/en/design-resources/boards-kits/fpb-ra8e1?partno=RTK7FPA8E1S00001BE" },
    .{ .id = "fpb-ra4t1", .board = "RTK7FPA4T1S00001BE", .sdk = "project-pinned FPB-RA4T1 startup, linker script and BSP/FSP dependencies", .probe = "target-supported probe/server and host USB access; board profile validation required", .image_tools = "project-specific ELF/flash image recipe", .npu_tools = "not applicable", .reference = "https://www.renesas.com/en/document/mat/fpb-ra4t1-v1-users-manual" },
    .{ .id = "grove-vision-ai-v2", .board = "101021112", .sdk = "project-pinned HimaxWiseEyePlus SDK plus its recursive dependencies; vendor recipes use Arm GNU and make", .probe = "vendor serial bootloader/driver or validated SWD probe; not generic RA flash", .image_tools = "vendor we2 image generator and xmodem/serial tools with pinned dependencies", .npu_tools = "matching Ethos-U55 model compiler/runtime and model artifacts; not provisioned", .reference = "https://github.com/HimaxWiseEyePlus/Seeed_Grove_Vision_AI_Module_V2" },
};

pub fn find(id: []const u8) !Target {
    for (targets) |target| if (std.mem.eql(u8, id, target.id)) return target;
    return error.UnknownTarget;
}
