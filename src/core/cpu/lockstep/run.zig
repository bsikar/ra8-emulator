//! A lockstep run: step both backends until the budget is spent, the Zig
//! core stops, Unicorn faults, or the two disagree, counting every
//! instruction under its class on the way.
const std = @import("std");
const engine = @import("../../engine.zig");
const cpu_mod = @import("../cpu.zig");
const Instr = @import("../instr.zig").Instr;
const step = @import("step.zig");
const tally = @import("tally.zig");
const history = @import("history.zig");

pub const End = union(enum) {
    budget,
    diverged: step.Divergence,
    stopped: cpu_mod.Stop,
    oracle_fault: engine.Fault,
};

pub const Run = struct {
    counts: tally.Tally = .{},
    /// The instructions both backends agreed on, latest last.
    recent: history.History = .{},
    /// The address of the instruction the run ended on.
    at: u32 = 0,

    pub fn deinit(self: *Run, gpa: std.mem.Allocator) void {
        self.counts.deinit(gpa);
    }

    pub fn go(self: *Run, gpa: std.mem.Allocator, ours: *cpu_mod.Cpu, theirs: engine.Engine, budget: u64) !End {
        var left = budget;
        while (left > 0) : (left -= 1) {
            const address = ours.regs.pc;
            self.at = address;
            const fetched = Instr.fetch(ours.bus, address) catch null;
            switch (try step.one(ours, theirs)) {
                .matched => |class| try self.counts.record(gpa, class, .matched),
                .diverged => |found| {
                    try self.counts.record(gpa, found.class, .diverged);
                    return .{ .diverged = found };
                },
                .stopped => |why| return .{ .stopped = why },
                .oracle_fault => |fault| return .{ .oracle_fault = fault },
            }
            if (fetched) |instr| self.recent.push(.{ .address = address, .instr = instr });
        }
        return .budget;
    }
};
