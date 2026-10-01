//! Test fixture, not a test file: two engines with the same program in board
//! SRAM, the Zig core on one and Unicorn on the other, both at the same state.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;
const EngineBus = ra8.core.cpu.engine_bus.EngineBus;
const Cpu = ra8.core.cpu.cpu.Cpu;
const regs = ra8.core.cpu.regs;
const snapshot = ra8.core.cpu.lockstep.snapshot;
const oracle = ra8.core.cpu.lockstep.oracle;

pub const entry: u32 = memmap.sram_base;

pub const Pair = struct {
    mine: Engine,
    theirs: Engine,
    memory: EngineBus,
    cpu: Cpu,

    /// Fill `self` in place: the Zig core's bus points back into it.
    pub fn open(self: *Pair, program: []const u8) !void {
        self.mine = try Engine.open();
        errdefer self.mine.close();
        self.theirs = try Engine.open();
        errdefer self.theirs.close();
        for ([_]*Engine{ &self.mine, &self.theirs }) |core| {
            try core.mapBoardRam();
            try core.write(entry, program);
        }
        self.memory = .{ .core = &self.mine };
        self.cpu = .{ .bus = self.memory.view() };
        self.cpu.regs.pc = entry;
        self.cpu.regs.xpsr = regs.xpsr_bits.thumb;
        self.cpu.regs.msp = entry + 0x1000;
        try oracle.load(self.theirs, snapshot.Snapshot.fromRegs(&self.cpu.regs));
    }

    pub fn close(self: *Pair) void {
        self.theirs.close();
        self.mine.close();
    }
};

comptime {
    std.debug.assert(entry % 4 == 0);
}
