//! How a session prints what it reads: registers, memory, an instruction.
//!
//! src/session/session.zig decides what to print; this file decides how, so
//! the formats sit in one place and a transcript changes only when one of
//! them does.

const core_view = @import("core_view.zig");
const disasm = @import("disasm.zig");
const elf = @import("ra8_board").image.elf;
const registers_list = @import("registers.zig");

pub const limits = struct {
    /// Words on one line of `x`.
    pub const words_per_line: u32 = 4;
};

pub const encoding = struct {
    /// A first halfword at or above this, with its top five bits 0b11101,
    /// 0b11110 or 0b11111, starts a 32-bit Thumb instruction.
    pub const wide_first: u16 = 0xE800;
    pub const narrow: u32 = 2;
    pub const wide: u32 = 4;
};

/// The core registers, in the order a register dump prints them.
pub fn registers(out: anytype, core: core_view.View) !void {
    for (registers_list.dumped, 0..) |named, index| {
        const value = try core.register(named.which);
        try out.print("{s: <3} 0x{X:0>8}", .{ named.name, value });
        try out.print("{s}", .{if (registers_list.endsLine(index)) "\n" else "  "});
    }
}

/// `count` words from `address`, a line every four.
pub fn words(out: anytype, core: core_view.View, address: u32, count: u32) !void {
    for (0..count) |step| {
        const index: u32 = @intCast(step);
        const at = address +% index * @sizeOf(u32);
        if (index % limits.words_per_line == 0) try out.print("0x{X:0>8}:", .{at});
        if (core.readWord(at)) |value| {
            try out.print(" 0x{X:0>8}", .{value});
        } else |_| {
            try out.print(" <unreadable>", .{});
        }
        const last = index + 1 == count;
        if (last or (index + 1) % limits.words_per_line == 0) try out.print("\n", .{});
    }
}

/// The word at a place, in hex and in decimal.
pub fn word(out: anytype, core: core_view.View, text: []const u8, address: u32) !void {
    const read = try core.readWord(address);
    try out.print("{s} = 0x{X:0>8} ({d})\n", .{ text, read, read });
}

/// The instruction at `address`, named by the image when the image puts a
/// name on where it goes, and how many bytes it takes.
pub fn instruction(out: anytype, core: core_view.View, image: ?elf.Image, address: u32) !u32 {
    const row = disasm.read(core, image, address);
    try out.print("{s}", .{row.text.slice()});
    return row.size;
}
