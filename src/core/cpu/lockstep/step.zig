//! One instruction on both backends, then a comparison of what each holds.
//!
//! Each backend needs its own memory, or a store by one would be read back
//! by the other and hide a divergence; the driver gives the Zig core an
//! engine of its own to fetch and store through.
const engine = @import("../../engine.zig");
const cpu_mod = @import("../cpu.zig");
const decode = @import("../decode.zig");
const Instr = @import("../instr.zig").Instr;
const snapshot = @import("snapshot.zig");
const diff = @import("diff.zig");
const oracle = @import("oracle.zig");

pub const Divergence = struct {
    class: []const u8,
    instr: Instr,
    mismatch: diff.Mismatch,
};

pub const Result = union(enum) {
    /// Both agree after the instruction; the payload is its class.
    matched: []const u8,
    diverged: Divergence,
    /// The Zig core did not execute it. Unicorn was not stepped either, so
    /// the two still agree.
    stopped: cpu_mod.Stop,
    /// The Zig core executed it and Unicorn faulted on it.
    oracle_fault: engine.Fault,
};

pub fn one(ours: *cpu_mod.Cpu, theirs: engine.Engine) engine.Error!Result {
    const address = ours.regs.pc;
    const instr = Instr.fetch(ours.bus, address) catch {
        return .{ .stopped = .{ .bus_fault = address } };
    };
    const hit = decode.decode(instr);
    if (ours.step()) |stopped| return .{ .stopped = stopped };
    const class = hit.?.group;
    if (try theirs.runChunk(address, 1, null)) |fault| return .{ .oracle_fault = fault };
    const mine = snapshot.Snapshot.fromRegs(&ours.regs);
    const other = try oracle.read(theirs);
    if (diff.first(mine, other)) |mismatch| {
        return .{ .diverged = .{ .class = class, .instr = instr, .mismatch = mismatch } };
    }
    return .{ .matched = class };
}
