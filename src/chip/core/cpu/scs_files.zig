//! Mirror SCS writes into the guest-visible register files.
const bus = @import("bus.zig");
const fp_scb = @import("fpu/scb.zig");
const fp_state = @import("fpu/state.zig");
const itm_port = @import("../../periph/itm.zig");
const memmap = @import("../memmap.zig");
const mpu = @import("../../periph/mpu/mpu.zig");
const sau = @import("../../periph/sau/sau.zig");
const std = @import("std");

/// File a word store into the SAU window and, when it moved RNR, put the
/// selected region's pair back in RAM so the next RBAR/RLAR read gives the
/// region RNR names rather than the last one programmed.
pub fn bankPartition(memory: bus.Bus, unit: *sau.Sau, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != 4 or address < memmap.sau.ctrl or address > memmap.sau.rlar) return;
    const word = std.mem.readInt(u32, bytes[0..4], .little);
    if (unit.observe(address, word) == .none) return;
    const pair = unit.bankedPair();
    try putWord(memory, memmap.sau.rbar, pair.rbar);
    try putWord(memory, memmap.sau.rlar, pair.rlar);
}

/// File a word store into the MPU window and, when it moved RNR, put the
/// four pairs RNR now selects back in RAM. A CTRL store is taken into the
/// table by `observe`.
/// `shift` is where the bank's copy sits above the normal window.
pub fn bankRegion(memory: bus.Bus, unit: *mpu.Mpu, address: u32, bytes: []const u8, shift: u32) bus.Error!void {
    if (bytes.len != 4 or address < memmap.mpu.type_ or address > memmap.mpu.mair1) return;
    const word = std.mem.readInt(u32, bytes[0..4], .little);
    if (unit.observe(address, word) != .rebank) return;
    const pairs = [_][2]u32{
        .{ memmap.mpu.rbar, memmap.mpu.rlar },
        .{ memmap.mpu.rbar_a1, memmap.mpu.rlar_a1 },
        .{ memmap.mpu.rbar_a2, memmap.mpu.rlar_a2 },
        .{ memmap.mpu.rbar_a3, memmap.mpu.rlar_a3 },
    };
    for (pairs, 0..) |where, offset| {
        const words = unit.pairFor(@intCast(offset));
        try putWord(memory, where[0] + shift, words[0]);
        try putWord(memory, where[1] + shift, words[1]);
    }
}

/// File a word store to FPCCR, FPCAR or FPDSCR in the FP state and put the
/// masked value back in RAM, so a plain RAM read agrees with the model.
pub fn fileFp(memory: bus.Bus, state: *fp_state.State, address: u32, bytes: []const u8) bus.Error!void {
    if (bytes.len != fp_scb.width) return;
    if (!fp_scb.write(state, address, std.mem.readInt(u32, bytes[0..4], .little))) return;
    try putWord(memory, address, fp_scb.read(state, address).?);
}

/// File a store into the ITM's registers and put back what a read of the
/// register sees, so a stimulus port polled after a character still reads
/// FIFOREADY rather than the character (RA8EMU-629).
pub fn fileItm(memory: bus.Bus, port: *itm_port.Itm, address: u32, bytes: []const u8) bus.Error!void {
    if (address < itm_port.base or address - itm_port.base >= itm_port.limits.span) return;
    const offset = address - itm_port.base;
    const width = @min(bytes.len, 4);
    var padded = @as([4]u8, @splat(0));
    @memcpy(padded[0..width], bytes[0..width]);
    if (!port.write(offset, std.mem.readInt(u32, &padded, .little), @intCast(width))) return;
    if (port.peek(offset)) |word| try putWord(memory, address, word);
}

pub fn putWord(memory: bus.Bus, address: u32, value: u32) bus.Error!void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try memory.write(address, &bytes);
}
