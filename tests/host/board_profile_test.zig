const std = @import("std");

const board_profile = @import("ra8").host.board_profile;

test "board profiles separate arrived bench qualification from absent or unpurchased hardware and emulation" {
    try std.testing.expectEqual(@as(usize, 5), board_profile.all.len);
    for (board_profile.all) |prof| {
        try std.testing.expect(!prof.emulation_claimed);
        try std.testing.expect(prof.sources.len != 0);
    }

    const e1 = try board_profile.find("fpb-ra8e1");
    try std.testing.expectEqual(board_profile.Availability.arrived_qualified, e1.availability);
    try std.testing.expectEqualStrings("RTK7FPA8E1S00001BE", e1.orderable_part);
    try std.testing.expectEqualStrings("R7FA8E1AFDCFB", e1.mcu_part);
    try std.testing.expect(e1.uart_wired);
    try std.testing.expectEqual(board_profile.CapabilityStatus.qualified, e1.capabilities.uart);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), e1.flash_window.?.base);
    try std.testing.expectEqual(@as(u32, 0x0300_A100), e1.flash_window.?.option_setting_base);
    try std.testing.expectEqual(@as(u32, 0x410F_D232), e1.swd.?.cpuid);
    try std.testing.expectEqualStrings("R7FA8E1AFDCFB", e1.swd.?.part_readback.?.expected_ascii);
    try std.testing.expect(std.mem.indexOf(u8, e1.memory_summary, "16 KiB ITCM @ 0x00000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, e1.memory_summary, "16 KiB DTCM @ 0x20000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, e1.memory_summary, "512 KiB SRAM1 @ 0x22060000") != null);
    try std.testing.expect(std.mem.indexOf(u8, e1.memory_summary, "1 KiB Standby SRAM @ 0x26000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, e1.memory_summary, "no SRAM0 @ 0x22000000") != null);
    try std.testing.expectEqual(@as(usize, 4), e1.sources.len);

    const t1 = try board_profile.find("fpb-ra4t1");
    try std.testing.expectEqual(board_profile.Availability.arrived_qualified, t1.availability);
    try std.testing.expectEqualStrings("RTK7FPA4T1S00001BE", t1.orderable_part);
    try std.testing.expectEqualStrings("R7FA4T1BB3CFM", t1.mcu_part);
    try std.testing.expect(std.mem.indexOf(u8, t1.core_topology, "FPv5-SP-D16") != null);
    try std.testing.expectEqual(@as(usize, 4), t1.sources.len);
    try std.testing.expect(!t1.uart_wired);
    try std.testing.expectEqual(board_profile.CapabilityStatus.unsupported, t1.capabilities.uart);
    try std.testing.expectEqual(@as(u32, 0x0000_0000), t1.flash_window.?.base);
    try std.testing.expectEqual(@as(u32, 0x0004_0000), t1.flash_window.?.size);
    try std.testing.expectEqual(@as(u32, 0x410F_D214), t1.swd.?.cpuid);
    try std.testing.expectEqualStrings("R7FA4T1BB3CFM", t1.swd.?.part_readback.?.expected_ascii);

    const d2 = try board_profile.find("ra8d2");
    try std.testing.expectEqual(board_profile.Availability.unavailable_on_bench, d2.availability);
    try std.testing.expectEqual(board_profile.CapabilityStatus.pending_hardware, d2.capabilities.flash_verify);

    const grove = try board_profile.find("grove-vision-ai-v2");
    try std.testing.expectEqual(board_profile.Availability.unavailable_on_bench, grove.availability);
    try std.testing.expect(grove.swd == null);
    try std.testing.expect(std.mem.indexOf(u8, grove.probe_transport, "not SWD") != null);

    const p1 = try board_profile.find("ra8p1");
    try std.testing.expectEqual(board_profile.Availability.unpurchased_unavailable, p1.availability);
    try std.testing.expectEqual(board_profile.CapabilityStatus.pending_hardware, p1.capabilities.halt_read_step);

    try std.testing.expectError(error.UnknownBoardProfile, board_profile.find("missing-board"));
}
