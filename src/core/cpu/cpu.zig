//! The Zig core: a register file, the bus it fetches through, and the
//! fetch-decode-execute step.
//!
//! RA8EMU-15 brings it up beside Unicorn. Until the lockstep harness reports
//! no divergence, Unicorn stays the default CPU and this one is opt-in.
const bus = @import("bus.zig");
const regs_mod = @import("regs.zig");
const reset_mod = @import("reset.zig");
const decode = @import("decode.zig");
const Instr = @import("instr.zig").Instr;

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
};

pub const Cpu = struct {
    regs: regs_mod.Regs = .{},
    bus: bus.Bus,
    /// Instructions retired since reset.
    retired: u64 = 0,

    pub fn reset(self: *Cpu, vtor: u32) bus.Error!void {
        try reset_mod.fromVectorTable(&self.regs, self.bus, vtor);
        self.retired = 0;
    }

    /// One instruction, or the reason there was none.
    pub fn step(self: *Cpu) ?Stop {
        const address = self.regs.pc;
        if (self.regs.xpsr & regs_mod.xpsr_bits.thumb == 0) return .{ .invalid_state = address };
        const instr = Instr.fetch(self.bus, address) catch return .{ .bus_fault = address };
        const hit = decode.decode(instr) orelse return .{ .unknown = instr };
        self.regs.pc = address +% instr.size;
        hit.exec(self, instr) catch {
            self.regs.pc = address;
            return .{ .bus_fault = address };
        };
        self.retired += 1;
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
