//! Covers src/chip/vendor/himax/hx6538/mailbox.zig: triggers, W1C clears, shared words, and mutexes.
const ra8 = @import("ra8");
const std = @import("std");

const mailbox = ra8.chip.vendor.himax.hx6538.mailbox;

test "mailbox trigger and W1C clear isolate CM55M and CM55S status" {
    var mb: mailbox.Mailbox = .{};
    try std.testing.expect(!mb.pendingM());
    try std.testing.expect(!mb.pendingS());

    mb.write(mailbox.regs.cm55s_trig, 0x05);
    try std.testing.expect(!mb.pendingM());
    try std.testing.expect(mb.pendingS());
    try std.testing.expectEqual(@as(u32, 0x05), mb.read(mailbox.regs.cm55s_status));

    mb.write(mailbox.regs.cm55s_clr, 0x01);
    try std.testing.expectEqual(@as(u32, 0x04), mb.read(mailbox.regs.cm55s_status));
    mb.write(mailbox.regs.cm55s_clr, 0x04);
    try std.testing.expect(!mb.pendingS());

    mb.write(mailbox.regs.cm55m_trig, 0x80);
    try std.testing.expect(mb.pendingM());
    mb.write(mailbox.regs.cm55m_clr, 0x80);
    try std.testing.expect(!mb.pendingM());
}

test "mailbox shared words and read-to-claim atomic mutexes" {
    var mb: mailbox.Mailbox = .{};
    mb.write(mailbox.regs.share_base + 0 * 4, 0xDEAD_BEEF);
    mb.write(mailbox.regs.share_base + 23 * 4, 0xCAFE_BABE);
    try std.testing.expectEqual(@as(u32, 0xDEAD_BEEF), mb.read(mailbox.regs.share_base));
    try std.testing.expectEqual(@as(u32, 0xCAFE_BABE), mb.read(mailbox.regs.share_base + 23 * 4));

    // Mutexes reset to 1 (unlocked); first read claims (returns 1, clears to 0).
    try std.testing.expectEqual(@as(u32, 1), mb.peek(mailbox.regs.mutex_base + 4));
    try std.testing.expectEqual(@as(u32, 1), mb.read(mailbox.regs.mutex_base + 4));
    try std.testing.expectEqual(@as(u32, 0), mb.read(mailbox.regs.mutex_base + 4));

    mb.write(mailbox.regs.mutex_base + 4, 1);
    try std.testing.expectEqual(@as(u32, 1), mb.read(mailbox.regs.mutex_base + 4));
}
