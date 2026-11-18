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
