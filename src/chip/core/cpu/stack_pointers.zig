const Cpu = @import("cpu.zig").Cpu;

/// The four stack pointers an instruction may move, taken before it runs so
/// a write that crosses MSPLIM or PSPLIM can be undone. SG and BXNS swap the
/// banks without moving a pointer, so each is compared in its own bank.
pub const StackPointers = struct {
    msp: u32,
    psp: u32,
    other_msp: u32,
    other_psp: u32,
    state: @TypeOf(@as(Cpu, undefined).banked.current),

    pub fn read(cpu: *const Cpu) StackPointers {
        return .{
            .msp = cpu.regs.msp,
            .psp = cpu.regs.psp,
            .other_msp = cpu.banked.other.msp,
            .other_psp = cpu.banked.other.psp,
            .state = cpu.banked.current,
        };
    }

    /// Whether a pointer the instruction changed now sits below its limit.
    pub fn overrun(self: StackPointers, cpu: *const Cpu) bool {
        const r = &cpu.regs;
        const o = &cpu.banked.other;
        const was = self.inBanks(cpu);
        return (r.msp != was.msp and r.msp < r.msplim) or
            (r.psp != was.psp and r.psp < r.psplim) or
            (o.msp != was.other_msp and o.msp < o.msplim) or
            (o.psp != was.other_psp and o.psp < o.psplim);
    }

    pub fn restore(self: StackPointers, cpu: *Cpu) void {
        const was = self.inBanks(cpu);
        cpu.regs.msp = was.msp;
        cpu.regs.psp = was.psp;
        cpu.banked.other.msp = was.other_msp;
        cpu.banked.other.psp = was.other_psp;
    }

    /// The snapshot laid out the way the banks sit now.
    fn inBanks(self: StackPointers, cpu: *const Cpu) StackPointers {
        if (cpu.banked.current == self.state) return self;
        return .{
            .msp = self.other_msp,
            .psp = self.other_psp,
            .other_msp = self.msp,
            .other_psp = self.psp,
            .state = cpu.banked.current,
        };
    }
};
