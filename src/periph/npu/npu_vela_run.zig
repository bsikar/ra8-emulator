//! Running a Vela command stream as far as this model can: the register
//! state it sets, and the DMA copies it starts.
//!
//! npu_vela.zig checks the stream's shape, npu_vela_regs.zig keeps what the
//! cmd1 commands set, and npu_vela_dma.zig does one copy. This file is the
//! loop over them. A block operation (conv, depthwise, pool, elementwise)
//! stops the run with error.OperatorNotModelled, so nothing that needs an
//! operator is reported as having run. DMA0_SRC_REGION and _DST_REGION
//! (cmd0 0x130 and 0x131) pick the regions the next DMA_START copies
//! between; any other register set is passed over for now.
const std = @import("std");
const vela = @import("npu_vela.zig");
const regs = @import("npu_vela_regs.zig");
const dma = @import("npu_vela_dma.zig");

pub const Error = vela.Error || dma.Error || error{OperatorNotModelled};

pub const Result = struct {
    summary: vela.Summary,
    /// Bytes every DMA_START in the program moved, together.
    moved: u64 = 0,
    state: regs.State = .{},
};

const Machine = struct {
    state: regs.State = .{},
    src: dma.Region = .{},
    dst: dma.Region = .{},
    moved: u64 = 0,
};

fn setRegister(machine: *Machine, code: u10, word: u32) void {
    switch (code) {
        dma.set_dma0_src_region => machine.src = dma.Region.fromParam(vela.param(word)),
        dma.set_dma0_dst_region => machine.dst = dma.Region.fromParam(vela.param(word)),
        else => {},
    }
}

fn operate(machine: *Machine, memory: anytype, regions: *const dma.Regions, op: vela.Op) Error!void {
    switch (op) {
        .conv, .depthwise, .pool, .elementwise => return error.OperatorNotModelled,
        .dma_start => machine.moved += try dma.copy(memory, regions, machine.src, machine.dst, machine.state.dma0),
        .stop, .irq, .dma_wait, .kernel_wait, .pmu_mask => {},
    }
}

/// Run `words` to their STOP against `memory`, with `regions` as BASEP.
pub fn run(memory: anytype, regions: *const dma.Regions, words: []const u32) Error!Result {
    const summary = try vela.walk(words);
    var machine = Machine{};
    var index: usize = 0;
    while (index < summary.words) {
        const word = words[index];
        if (word & vela.mode_mask == vela.mode_payload32) {
            _ = regs.apply(&machine.state, word, words[index + 1]);
            index += 2;
            continue;
        }
        index += 1;
        const code: u10 = @truncate(word & vela.opcode_mask);
        if (vela.isCmd0Set(code)) {
            setRegister(&machine, code, word);
            continue;
        }
        // walk() already refused any opcode outside Op.
        try operate(&machine, memory, regions, @enumFromInt(code));
    }
    return .{ .summary = summary, .moved = machine.moved, .state = machine.state };
}
