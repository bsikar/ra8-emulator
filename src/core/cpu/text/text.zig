//! One instruction as UAL text, in the shape Capstone prints it (RA8EMU-253):
//! the mnemonic, one space, then the operands. Registers use Capstone's names
//! (r9-r12 are sb, sl, fp and ip) and an immediate under ten is decimal, any
//! other is lowercase hex.
const std = @import("std");

pub const names = [16][]const u8{
    "r0", "r1", "r2", "r3", "r4", "r5", "r6", "r7",
    "r8", "sb", "sl", "fp", "ip", "sp", "lr", "pc",
};

/// Capstone prints immediates below this in decimal.
pub const decimal_below: u32 = 10;

pub const Text = struct {
    buffer: [64]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.buffer[0..self.len];
    }

    /// Append formatted text; anything past the buffer is dropped.
    pub fn put(self: *Text, comptime fmt: []const u8, args: anytype) void {
        const out = std.fmt.bufPrint(self.buffer[self.len..], fmt, args) catch return;
        self.len += out.len;
    }

    pub fn reg(self: *Text, r: u4) void {
        self.put("{s}", .{names[r]});
    }

    pub fn imm(self: *Text, value: u32) void {
        if (value < decimal_below) self.put("#{d}", .{value}) else self.put("#0x{x}", .{value});
    }

    /// `mnemonic rd, rm`.
    pub fn regs2(self: *Text, mnemonic: []const u8, rd: u4, rm: u4) void {
        self.put("{s} {s}, {s}", .{ mnemonic, names[rd], names[rm] });
    }

    /// `mnemonic rd, rn, rm`.
    pub fn regs3(self: *Text, mnemonic: []const u8, rd: u4, rn: u4, rm: u4) void {
        self.put("{s} {s}, {s}, {s}", .{ mnemonic, names[rd], names[rn], names[rm] });
    }
};

/// The low three bits at `at` as a register.
pub fn low(hw: u16, comptime at: u4) u4 {
    return @intCast((hw >> at) & 0x7);
}
