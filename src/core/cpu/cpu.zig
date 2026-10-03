//! The Zig core: a register file, the bus it fetches through, and the
//! fetch-decode-execute step.
//!
//! RA8EMU-15 brings it up beside Unicorn. Until the lockstep harness reports
//! no divergence, Unicorn stays the default CPU and this one is opt-in.
const bus = @import("bus.zig");
const regs_mod = @import("regs.zig");
const reset_mod = @import("reset.zig");
const decode = @import("decode.zig");
const decode_cache = @import("decode_cache.zig");
const cond = @import("cond.zig");
const it_state = @import("it_state.zig");
const Instr = @import("instr.zig").Instr;
const fp_state = @import("fpu/state.zig");
const exception = @import("exception/all.zig");
const banked_mod = @import("../banked.zig");
pub const bti = @import("bti.zig");

/// Why `run` or `step` stopped.
pub const Stop = union(enum) {
    /// Ran every instruction it was asked to.
    count,
    /// No group in the decode table knows this encoding. The PC is left on
    /// it and nothing has changed.
    unknown: Instr,
    /// EPSR.T is clear at this address and the INVSTATE UsageFault it raises
    /// locked up or could not be stacked.
    invalid_state: u32,
    /// The fetch at this address, or an access the instruction there made,
    /// reached memory nothing answers for. The PC is left on it.
    bus_fault: u32,
    /// The instruction at this address branched to an EXC_RETURN value the
    /// core cannot honour, or to one whose stacked frame contradicts it, and
    /// the INVPC UsageFault it raises locked up or could not be taken.
    invalid_return: u32,
    /// The instruction at this address made an unaligned access and the
    /// UNALIGNED UsageFault it raises locked up or could not be stacked. The
    /// PC is left on it.
    unaligned: u32,
    /// A BKPT at this address halted the core for an attached debugger
    /// (DHCSR.C_DEBUGEN), or the HardFault it escalated to locked up. The PC
    /// is left on it.
    breakpoint: u32,
    /// The instruction crossed MSPLIM or PSPLIM and its STKOF UsageFault
    /// locked up or could not be stacked.
    stack_overflow: u32,
};

/// A listener called once for each instruction that retires.
pub const RetireListener = struct {
    context: *anyopaque,
    instructionFn: *const fn (context: *anyopaque, address: u32) void,

    pub fn instruction(self: RetireListener, address: u32) void {
        self.instructionFn(self.context, address);
    }
};

pub const Cpu = struct {
    regs: regs_mod.Regs = .{},
    bus: bus.Bus,
    /// S0-S31/D0-D15 and FPSCR, for the FPU groups (RA8EMU-26).
    fp: fp_state.State = .{},
    /// Instructions retired since reset.
    retired: u64 = 0,
    /// Optional observer for each retired instruction (profiling/debugging).
    retire_listener: ?RetireListener = null,
    /// The vector table the core reset from, for exception entry while
    /// nothing answers at VTOR.
    vtor: u32 = 0,
    /// An exception the instruction just executed raises (SVC), taken once
    /// it retires.
    raised: ?exception.entry.Number = null,
    /// The exceptions the core is inside.
    active: exception.active.Active = .{},
    /// What is pending, asked before each instruction `run` executes. Null
    /// runs with no asynchronous exceptions, as a lockstep step does.
    source: ?exception.source.Source = null,
    /// The poll shortcut `source` and `bus` go through on the board, stirred
    /// as each `run` starts because the board moves between stretches.
    quiet: ?*exception.quiet_source.QuietSource = null,
    /// Decodes kept per address on the board; null decodes every step.
    decoded: ?*decode_cache.DecodeCache = null,
    /// The local exclusive monitor: the address a load-exclusive tagged.
    exclusive: ?u32 = null,
    /// The other Security state's banked registers, which Secure code reaches
    /// through the _NS forms of MRS and MSR.
    banked: banked_mod.Banked = .{},
    /// The event register WFE waits on: set by SEV and by exception entry
    /// and return, cleared by a WFE that finds it set.
    event: bool = false,
    /// What a WFI or WFE left the core waiting for, or null while it runs.
    waiting: ?exception.sleep.Wait = null,
    /// Which encodings this core implements: an M85's unless the board
    /// says otherwise (src/core/part.zig, RA8EMU-233).
    profile: decode.profile.Profile = decode.profile.Profile.m85,

    pub fn reset(self: *Cpu, vtor: u32) bus.Error!void {
        try reset_mod.fromVectorTable(&self.regs, self.bus, vtor);
        self.retired = 0;
        self.vtor = vtor;
        self.raised = null;
        self.active = .{};
        self.event = false;
        self.waiting = null;
    }

    /// One instruction, or the reason there was none.
    pub fn step(self: *Cpu) ?Stop {
        const address = self.regs.pc;
        if (self.regs.xpsr & regs_mod.xpsr_bits.thumb == 0) return self.usageFault(.invstate, address, .{ .invalid_state = address });
        const instr = Instr.fetch(self.bus, address) catch return .{ .bus_fault = address };
        const it = it_state.get(self.regs.xpsr);
        const runs = !it_state.active(it) or cond.passed(it_state.condition(it), self.regs.xpsr);
        if (runs and self.regs.xpsr & regs_mod.xpsr_bits.bti != 0 and bti.enabled(&self.regs, self.profile.v8_1m) and !bti.allowed(instr))
            return self.usageFault(.invstate, address, .{ .invalid_state = address });
        const found = if (self.decoded) |cache| cache.findFor(self.profile, instr) else decode.decodeFor(self.profile, instr);
        // An encoding whose IT condition failed never runs, so it is skipped
        // whether or not any group knows it.
        if (found == null and runs) {
            if (decode.refused(self.profile, instr)) return self.usageFault(.undefinstr, address, .{ .unknown = instr });
            return .{ .unknown = instr };
        }
        self.regs.pc = address +% instr.size;
        if (runs) {
            const before = StackPointers.read(self);
            found.?.exec(self, instr) catch |err| {
                self.regs.pc = address;
                return switch (err) {
                    error.Unaligned => self.usageFault(.unaligned, address, .{ .unaligned = address }),
                    error.Undefined => self.usageFault(.undefinstr, address, .{ .unknown = instr }),
                    error.Breakpoint => self.breakpoint(address),
                    error.StackOverflow => self.usageFault(.stkof, address, .{ .stack_overflow = address }),
                    error.InvalidState => self.usageFault(.invstate, address, .{ .invalid_state = address }),
                    else => .{ .bus_fault = address },
                };
            };
            if (before.overrun(self)) {
                before.restore(self);
                self.regs.pc = address;
                return self.usageFault(.stkof, address, .{ .stack_overflow = address });
            }
        }
        // An instruction an IT block governs moves the block on whether it
        // ran or not. IT itself leaves the state it just wrote.
        if (it_state.active(it)) self.regs.xpsr = it_state.put(self.regs.xpsr, it_state.advance(it));
        self.retired += 1;
        if (self.retire_listener) |listener| listener.instruction(address);
        return self.finish(address);
    }

    /// What an instruction leaves for after it retires and its IT state has
    /// moved on: an exception return, or an exception it raised.
    fn finish(self: *Cpu, address: u32) ?Stop {
        if (self.regs.exc_return) |value| {
            self.regs.exc_return = null;
            exception.ret.from(self, value) catch |err| return switch (err) {
                error.InvalidReturn => {
                    exception.fault.invalidReturn(self, value) catch return .{ .invalid_return = address };
                    return null;
                },
                else => .{ .bus_fault = address },
            };
            exception.dispatch.left(self) catch return .{ .bus_fault = address };
        }
        if (self.raised) |number| {
            self.raised = null;
            exception.dispatch.supervisorCall(self, number, self.regs.pc) catch return .{ .bus_fault = address };
        }
        return null;
    }

    /// Take a UsageFault the instruction at `address` caused, or stop with
    /// `otherwise` when it locks up or the frame cannot be stacked.
    fn usageFault(self: *Cpu, cause: exception.fault.Cause, address: u32, otherwise: Stop) ?Stop {
        exception.fault.usage(self, cause, address) catch return otherwise;
        return null;
    }

    /// Take the debug event a BKPT at `address` raises, or stop on it for an
    /// attached debugger or when the HardFault it escalates to locks up.
    fn breakpoint(self: *Cpu, address: u32) ?Stop {
        const taken = exception.debug_event.breakpoint(self, address) catch return .{ .breakpoint = address };
        return if (taken) null else .{ .breakpoint = address };
    }

    pub fn run(self: *Cpu, count: u64) Stop {
        if (self.quiet) |q| q.stir();
        var left = count;
        while (left > 0) : (left -= 1) {
            const taken = exception.dispatch.poll(self) catch return .{ .bus_fault = self.regs.pc };
            if (taken) self.waiting = null;
            if (self.waiting) |why| {
                const up = exception.sleep.wakes(self, why) catch return .{ .bus_fault = self.regs.pc };
                // Asleep with nothing to wake it: nothing changes before the
                // next boundary, so the rest of the stretch goes by at once.
                if (!up) return .count;
                self.waiting = null;
            }
            if (self.step()) |stopped| return stopped;
        }
        return .count;
    }
};

/// The four stack pointers an instruction may move, taken before it runs so
/// a write that crosses MSPLIM or PSPLIM can be undone.
const StackPointers = struct {
    msp: u32,
    psp: u32,
    other_msp: u32,
    other_psp: u32,

    fn read(cpu: *const Cpu) StackPointers {
        return .{
            .msp = cpu.regs.msp,
            .psp = cpu.regs.psp,
            .other_msp = cpu.banked.other.msp,
            .other_psp = cpu.banked.other.psp,
        };
    }

    /// Whether a pointer the instruction changed now sits below its limit.
    fn overrun(self: StackPointers, cpu: *const Cpu) bool {
        const r = &cpu.regs;
        const o = &cpu.banked.other;
        return (r.msp != self.msp and r.msp < r.msplim) or
            (r.psp != self.psp and r.psp < r.psplim) or
            (o.msp != self.other_msp and o.msp < o.msplim) or
            (o.psp != self.other_psp and o.psp < o.psplim);
    }

    fn restore(self: StackPointers, cpu: *Cpu) void {
        cpu.regs.msp = self.msp;
        cpu.regs.psp = self.psp;
        cpu.banked.other.msp = self.other_msp;
        cpu.banked.other.psp = self.other_psp;
    }
};
