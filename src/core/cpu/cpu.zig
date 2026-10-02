//! The Zig core: a register file, the bus it fetches through, and the
//! fetch-decode-execute step.
//!
//! RA8EMU-15 brings it up beside Unicorn. Until the lockstep harness reports
//! no divergence, Unicorn stays the default CPU and this one is opt-in.
const bus = @import("bus.zig");
const regs_mod = @import("regs.zig");
const reset_mod = @import("reset.zig");
const decode = @import("decode.zig");
const cond = @import("cond.zig");
const it_state = @import("it_state.zig");
const Instr = @import("instr.zig").Instr;
const fp_state = @import("fpu/state.zig");
const exception = @import("exception/all.zig");

/// Why `run` or `step` stopped.
pub const Stop = union(enum) {
    /// Ran every instruction it was asked to.
    count,
    /// No group in the decode table knows this encoding. The PC is left on
    /// it and nothing has changed.
    unknown: Instr,
    /// EPSR.T is clear at this address, which is an INVSTATE UsageFault the
    /// core does not take yet.
    invalid_state: u32,
    /// The fetch at this address, or an access the instruction there made,
    /// reached memory nothing answers for. The PC is left on it.
    bus_fault: u32,
    /// The instruction at this address branched to an EXC_RETURN value the
    /// core cannot honour, or to one whose stacked frame contradicts it: an
    /// INVPC UsageFault the core does not take yet.
    invalid_return: u32,
};

pub const Cpu = struct {
    regs: regs_mod.Regs = .{},
    bus: bus.Bus,
    /// S0-S31/D0-D15 and FPSCR, for the FPU groups (RA8EMU-26).
    fp: fp_state.State = .{},
    /// Instructions retired since reset.
    retired: u64 = 0,
    /// The vector table the core reset from, for exception entry while
    /// nothing answers at VTOR.
    vtor: u32 = 0,
    /// An exception the instruction just executed raises (SVC), taken once
    /// it retires.
    raised: ?exception.entry.Number = null,

    pub fn reset(self: *Cpu, vtor: u32) bus.Error!void {
        try reset_mod.fromVectorTable(&self.regs, self.bus, vtor);
        self.retired = 0;
        self.vtor = vtor;
        self.raised = null;
    }

    /// One instruction, or the reason there was none.
    pub fn step(self: *Cpu) ?Stop {
        const address = self.regs.pc;
        if (self.regs.xpsr & regs_mod.xpsr_bits.thumb == 0) return .{ .invalid_state = address };
        const instr = Instr.fetch(self.bus, address) catch return .{ .bus_fault = address };
        const hit = decode.decode(instr) orelse return .{ .unknown = instr };
        self.regs.pc = address +% instr.size;
        const it = it_state.get(self.regs.xpsr);
        if (!it_state.active(it) or cond.passed(it_state.condition(it), self.regs.xpsr)) {
            hit.exec(self, instr) catch {
                self.regs.pc = address;
                return .{ .bus_fault = address };
            };
        }
        // An instruction an IT block governs moves the block on whether it
        // ran or not. IT itself leaves the state it just wrote.
        if (it_state.active(it)) self.regs.xpsr = it_state.put(self.regs.xpsr, it_state.advance(it));
        self.retired += 1;
        return self.finish(address);
    }

    /// What an instruction leaves for after it retires and its IT state has
    /// moved on: an exception return, or an exception it raised.
    fn finish(self: *Cpu, address: u32) ?Stop {
        if (self.regs.exc_return) |value| {
            self.regs.exc_return = null;
            exception.ret.from(self, value) catch |err| return switch (err) {
                error.InvalidReturn => .{ .invalid_return = address },
                else => .{ .bus_fault = address },
            };
        }
        if (self.raised) |number| {
            self.raised = null;
            exception.entry.take(self, number, self.regs.pc) catch return .{ .bus_fault = address };
        }
        return null;
    }

    pub fn run(self: *Cpu, count: u64) Stop {
        var left = count;
        while (left > 0) : (left -= 1) {
            if (self.step()) |stopped| return stopped;
        }
        return .count;
    }
};
