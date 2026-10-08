//! One fetched Thumb instruction: where it sits, its halfwords and its width.
const std = @import("std");
const bus = @import("bus.zig");

pub const Instr = struct {
    address: u32,
    hw1: u16,
    /// The second halfword of a 32-bit encoding; zero for a 16-bit one.
    hw2: u16 = 0,
    /// 2 or 4 bytes.
    size: u32,

    /// Whether a first halfword opens a 32-bit encoding: bits [15:11] are
    /// 0b11101, 0b11110 or 0b11111.
    pub fn isWide(hw1: u16) bool {
        return (hw1 >> 11) >= 0b11101;
    }

    /// Fetch the instruction at `address`, reading the second halfword only
    /// when the first one says there is one.
    pub fn fetch(from: bus.Bus, address: u32) bus.Error!Instr {
        const hw1 = try from.readHalf(address);
        if (!isWide(hw1)) return .{ .address = address, .hw1 = hw1, .size = 2 };
        const hw2 = try from.readHalf(address +% 2);
        return .{ .address = address, .hw1 = hw1, .hw2 = hw2, .size = 4 };
    }

    /// `0x08001234: 0xf3af 0x8000`, the shape an unknown-encoding report and
    /// a lockstep divergence print an instruction in.
    pub fn format(self: Instr, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("0x{x:0>8}: 0x{x:0>4}", .{ self.address, self.hw1 });
        if (self.size == 4) try writer.print(" 0x{x:0>4}", .{self.hw2});
    }
};
