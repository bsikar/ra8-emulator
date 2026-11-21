//! Unit tests for classic RA4T1 `SCI0` (`0x4011_8000`) and `SCI9` (`0x4011_8900`).
const ra8 = @import("ra8");
const std = @import("std");

const sci = ra8.chip.vendor.renesas.ra4t1.sci;

const SinkCapture = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    last_ch: u4 = 0,

    fn onByte(ctx: *anyopaque, ch: u4, byte: u8) void {
        const self: *SinkCapture = @ptrCast(@alignCast(ctx));
        self.last_ch = ch;
        if (self.len < self.buf.len) {
            self.buf[self.len] = byte;
            self.len += 1;
        }
    }
};

test "classic SCI reset defaults and BRR/MDDR enable lock match HUM Ch 24" {
    var unit = sci.Sci.init();
    try std.testing.expectEqual(@as(u32, 0x84), unit.read(1, sci.ofs.ssr, 1));
    try std.testing.expectEqual(@as(u32, 0xF2), unit.read(1, sci.ofs.scmr, 1));
    try std.testing.expectEqual(@as(u32, 0xF800), unit.read(1, sci.ofs.fcr, 2));
    try std.testing.expectEqual(@as(u32, 0x03), unit.read(1, sci.ofs.sptr, 1));

    // BRR and MDDR update while TE=0, RE=0, and ignore stores once enabled.
    unit.write(1, sci.ofs.brr, 1, 4);
    unit.write(1, sci.ofs.mddr, 1, 236);
    unit.write(1, sci.ofs.scr, 1, 0x30);
    unit.write(1, sci.ofs.brr, 1, 99);
    unit.write(1, sci.ofs.mddr, 1, 128);
    try std.testing.expectEqual(@as(u32, 4), unit.read(1, sci.ofs.brr, 1));
    try std.testing.expectEqual(@as(u32, 236), unit.read(1, sci.ofs.mddr, 1));
}

test "SCI9 transmits via TDR to sink and receives bytes into RDR with RDRF" {
    var capture: SinkCapture = .{};
    var unit = sci.Sci.init();
    unit.tx_sink = .{ .context = &capture, .onByteFn = SinkCapture.onByte };
    unit.write(1, sci.ofs.scr, 1, 0x30);
    unit.write(1, sci.ofs.tdr, 1, 'O');
    unit.write(1, sci.ofs.tdr, 1, 'K');
    try std.testing.expectEqual(@as(u4, 9), capture.last_ch);
    try std.testing.expectEqualStrings("OK", capture.buf[0..capture.len]);
    try std.testing.expect((unit.read(1, sci.ofs.ssr, 1) & 0x84) == 0x84);

    try std.testing.expect(unit.pushRx(1, '!'));
    try std.testing.expectEqual(@as(u32, '!'), unit.read(1, sci.ofs.rdr, 1));
    try std.testing.expect((unit.read(1, sci.ofs.ssr, 1) & sci.ssr_bit.rdrf) != 0);
}
