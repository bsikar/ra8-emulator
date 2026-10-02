//! Walking a real Vela command stream: which words are commands, which are
//! payloads, and what the program asks the NPU to do before it stops.
//!
//! This is the first step from the stand-in program in npu_cmd.zig toward
//! running what Vela actually emits. Nothing executes here yet; the walk
//! only splits the stream into commands and counts the operations, so the
//! later slices (register state, DMA, the operators) have a decoded program
//! to work from.
//!
//! Encoding, from Arm's Vela 3.12.0 (Apache-2.0): ethos_u55_regs.py and
//! register_command_stream_generator.py. Each command word carries its
//! opcode in bits [9:0], its mode in bits [15:14] and a 16-bit parameter in
//! bits [31:16]. Mode 0 (cmd0) is the word alone; mode 1 (cmd1, 0x4000) is
//! followed by one 32-bit payload word. The other two modes are not emitted.
const std = @import("std");

/// What NPU_OP_DMA_START copies, kept beside the walk so root.zig stays one line.
pub const dma = @import("npu_vela_dma.zig");

pub const opcode_mask: u32 = 0x03FF;
pub const mode_mask: u32 = 0xC000;
pub const mode_payload32: u32 = 0x4000;

/// The cmd0 opcodes the Ethos-U55 defines (ethos_u55_regs.py `cmd0`).
pub const Op = enum(u10) {
    stop = 0x000,
    irq = 0x001,
    conv = 0x002,
    depthwise = 0x003,
    pool = 0x005,
    elementwise = 0x006,
    dma_start = 0x010,
    dma_wait = 0x011,
    kernel_wait = 0x012,
    pmu_mask = 0x013,
};

/// What a walk found in the program.
pub const Summary = struct {
    /// Words up to and including the STOP.
    words: usize = 0,
    /// cmd1 register writes, each with its payload.
    register_writes: usize = 0,
    conv: usize = 0,
    depthwise: usize = 0,
    pool: usize = 0,
    elementwise: usize = 0,
    dma_starts: usize = 0,
    waits: usize = 0,
    irqs: usize = 0,
    /// The STOP's 16-bit mask parameter.
    stop_mask: u16 = 0,

    /// Block operations the program runs (the operators, not the DMA).
    pub fn operations(self: Summary) usize {
        return self.conv + self.depthwise + self.pool + self.elementwise;
    }
};

pub const Error = error{ Truncated, UnknownMode, UnknownOpcode, NoStop };

/// The 16-bit parameter of a command word.
pub fn param(word: u32) u16 {
    return @truncate(word >> 16);
}

fn count(summary: *Summary, op: Op, word: u32) void {
    switch (op) {
        .stop => summary.stop_mask = param(word),
        .irq => summary.irqs += 1,
        .conv => summary.conv += 1,
        .depthwise => summary.depthwise += 1,
        .pool => summary.pool += 1,
        .elementwise => summary.elementwise += 1,
        .dma_start => summary.dma_starts += 1,
        .dma_wait, .kernel_wait => summary.waits += 1,
        .pmu_mask => {},
    }
}

/// Walk `words` from the first command to the STOP.
pub fn walk(words: []const u32) Error!Summary {
    var summary = Summary{};
    var index: usize = 0;
    while (index < words.len) {
        const word = words[index];
        const mode = word & mode_mask;
        if (mode == mode_payload32) {
            if (index + 1 >= words.len) return error.Truncated;
            summary.register_writes += 1;
            index += 2;
            continue;
        }
        if (mode != 0) return error.UnknownMode;
        const code: u10 = @truncate(word & opcode_mask);
        const op = std.meta.intToEnum(Op, code) catch return error.UnknownOpcode;
        count(&summary, op, word);
        index += 1;
        if (op == .stop) {
            summary.words = index;
            return summary;
        }
    }
    return error.NoStop;
}
