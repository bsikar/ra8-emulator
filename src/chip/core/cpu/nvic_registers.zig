//! NVIC firmware commands over the core's backing register state.
//! Arm DDI0553B.y D1.2.183–187: word-only ISER/ISPR W1S and ICER/ICPR
//! W1C, sharing state across Security views and masking NS by ITNS.
const std = @import("std");
const bus = @import("bus.zig");
const alias = @import("../../periph/scs_alias.zig");
const nvic = @import("../../periph/nvic/nvic.zig");
const memmap = @import("../memmap.zig");

const span: u32 = 0x40;
const Command = struct { state: u32, word: u32, clear: bool };

fn command(address: u32) ?Command {
    for ([_]u32{ memmap.nvic.iser, memmap.nvic.icer, memmap.nvic.ispr, memmap.nvic.icpr }) |base| {
        if (address < base or address - base >= span) continue;
        const clear = base == memmap.nvic.icer or base == memmap.nvic.icpr;
        const word = (address - base) / 4;
        return .{ .state = (if (clear) base - 0x80 else base) + word * 4, .word = word, .clear = clear };
    }
    return null;
}

/// Whether a debugger range intersects a command register array.
pub fn touches(address: u32, len: usize) bool {
    if (len == 0) return false;
    const end = @as(u64, address) + len;
    for ([_]u32{ 0, alias.offset }) |offset| {
        for ([_]u32{ memmap.nvic.iser, memmap.nvic.icer, memmap.nvic.ispr, memmap.nvic.icpr }) |base| {
            const first = @as(u64, base) + offset;
            if (address < first + span and end > first) return true;
        }
    }
    return false;
}

pub fn covers(address: u32) bool {
    const at = if (address >= alias.scs_ns.first and address <= alias.scs_ns.last) address - alias.offset else address;
    return command(at) != null;
}

fn view(address: u32, secure: bool) ?alias.Target {
    return switch (alias.route(address, secure)) {
        .register => |target| target,
        .outside, .res0 => null,
    };
}

fn mask(memory: bus.Bus, target: alias.Target, word: u32) bus.Error!u32 {
    if (word >= nvic.irq_words) return 0;
    if (target.view == .secure) return std.math.maxInt(u32);
    return memory.readWord(nvic.itns.base + word * 4);
}

/// Narrow and unaligned command accesses are UNPREDICTABLE in the ARM;
/// this emulator refuses them without changing state.
fn width(address: u32, len: usize) bus.Error!void {
    if (len != 4 or address & 3 != 0) return error.Unmapped;
}

pub fn read(memory: bus.Bus, address: u32, secure: bool, into: []u8) bus.Error!void {
    const target = view(address, secure) orelse return @memset(into, 0);
    try width(address, into.len);
    const cmd = command(target.address) orelse return error.Unmapped;
    const allowed = try mask(memory, target, cmd.word);
    const value = if (allowed == 0) 0 else (try memory.readWord(cmd.state)) & allowed;
    std.mem.writeInt(u32, into[0..4], value, .little);
}

pub fn write(memory: bus.Bus, address: u32, secure: bool, bytes: []const u8) bus.Error!void {
    const target = view(address, secure) orelse return;
    try width(address, bytes.len);
    const cmd = command(target.address) orelse return error.Unmapped;
    const bits = std.mem.readInt(u32, bytes[0..4], .little) & (try mask(memory, target, cmd.word));
    if (bits == 0) return;
    const old = try memory.readWord(cmd.state);
    try memory.writeWord(cmd.state, if (cmd.clear) old & ~bits else old | bits);
}
