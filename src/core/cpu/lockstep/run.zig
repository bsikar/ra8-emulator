//! A lockstep run: step both backends until the budget is spent, the Zig
//! core stops, Unicorn faults, or the two disagree, counting every
//! instruction under its class on the way.
const std = @import("std");
const engine = @import("../../engine.zig");
const cpu_mod = @import("../cpu.zig");
const Instr = @import("../instr.zig").Instr;
const fault_clear = @import("../../../periph/fault_clear.zig");
const step = @import("step.zig");
const tally = @import("tally.zig");
const history = @import("history.zig");
const periph_log = @import("periph_log.zig");

pub const End = union(enum) {
    budget,
    diverged: step.Divergence,
    stopped: cpu_mod.Stop,
    oracle_fault: engine.Fault,
    secure_fault: step.SecureFault,
};

/// Called every `Run.round` instructions, so a second core can take its
/// turn between CPU0's (RA8EMU-235).
pub const Between = struct {
    context: *anyopaque,
    roundFn: *const fn (context: *anyopaque, instructions: u32) anyerror!void,
};

pub const Run = struct {
    counts: tally.Tally = .{},
    between: ?Between = null,
    round: u32 = 1000,
    /// The instructions both backends agreed on, latest last.
    recent: history.History = .{},
    /// The address of the instruction the run ended on.
    at: u32 = 0,
    /// Unicorn's fault-clear latch, when the board wired one (step.zig).
    settle: ?*fault_clear.Clears = null,

    pub fn deinit(self: *Run, gpa: std.mem.Allocator) void {
        self.counts.deinit(gpa);
    }

    pub fn go(self: *Run, gpa: std.mem.Allocator, ours: *cpu_mod.Cpu, theirs: engine.Engine, log: *periph_log.Log, budget: u64) !End {
        var left = budget;
        var since: u32 = 0;
        while (left > 0) : (left -= 1) {
            if (self.between) |hook| {
                since += 1;
                if (since > self.round) {
                    try hook.roundFn(hook.context, self.round);
                    since = 1;
                }
            }
            const address = ours.regs.pc;
            self.at = address;
            const fetched = Instr.fetch(ours.bus, address) catch null;
            switch (try step.one(ours, theirs, log, self.settle)) {
                .matched => |class| try self.counts.record(gpa, class, .matched),
                .skipped => |class| try self.counts.record(gpa, class, .skipped),
                .diverged => |found| {
                    try self.counts.record(gpa, found.class, .diverged);
                    return .{ .diverged = found };
                },
                .stopped => |why| return .{ .stopped = why },
                .oracle_fault => |fault| return .{ .oracle_fault = fault },
                .secure_fault => |found| return .{ .secure_fault = found },
            }
            if (fetched) |instr| self.recent.push(.{ .address = address, .instr = instr });
        }
        return .budget;
    }
};
