const std = @import("std");

const identity = @import("ra8").host.jlink.identity;

test "CPUID and serial verification rejects mismatched probe or core" {
    const sample =
        "Firmware: J-Link OB-RA4M2 compiled Feb 20 2025 16:34:52\r\n" ++
        "S/N: 1083322193\r\n" ++
        "Found Cortex-M85 r0p2, Little endian.\r\n" ++
        "E000ED00 = 410FD232 \r\n" ++
        "PC = 02000996, CycleCnt = 00001234\r\n" ++
        "SP(R13)= 22000610, MSP= 22000610, PSP= 00000000, R14(LR) = 02000341\r\n";
    const found = try identity.parse(sample);
    try std.testing.expectEqual(@as(u64, 1083322193), found.serial);
    try std.testing.expectEqual(@as(u32, 0x410FD232), found.cpuid);
    try identity.check(found, 1083322193, 0x410FD232);
    try std.testing.expectError(error.WrongProbe, identity.check(found, 1088957027, 0x410FD232));
    try std.testing.expectError(error.WrongCore, identity.check(found, 1083322193, 0x410FD214));

    const regs = try identity.parseRegisters(sample);
    try std.testing.expectEqual(@as(u32, 0x02000996), regs.pc);
    try std.testing.expectEqual(@as(u32, 0x22000610), regs.sp);
}

test "factory PNR0..3 readback decodes exact Renesas part numbers and rejects part mismatches" {
    const sample_e1 =
        "S/N: 1083322193\r\n" ++
        "E000ED00 = 410FD232 \r\n" ++
        "030080F0 = 41463752 41314538 46434446 20202042 \r\n";
    const found_e1 = try identity.parseWithPart(sample_e1, 0x0300_80F0);
    try std.testing.expectEqualStrings("R7FA8E1AFDCFB", found_e1.partSlice());
    try identity.checkWithPart(found_e1, 1083322193, 0x410FD232, "R7FA8E1AFDCFB");
    try std.testing.expectError(
        error.WrongPart,
        identity.checkWithPart(found_e1, 1083322193, 0x410FD232, "R7FA4T1BB3CFM"),
    );

    const sample_t1 =
        "S/N: 1088957027\r\n" ++
        "E000ED00 = 410FD214 \r\n" ++
        "010080F0 = 41463752 42315434 46433342 2020204D \r\n";
    const found_t1 = try identity.parseWithPart(sample_t1, 0x0100_80F0);
    try std.testing.expectEqualStrings("R7FA4T1BB3CFM", found_t1.partSlice());
    try identity.checkWithPart(found_t1, 1088957027, 0x410FD214, "R7FA4T1BB3CFM");
}
