//! One instruction on both backends, then a comparison of what each holds:
//! the registers, and every store the Zig core made.
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
const writes = @import("writes.zig");
const memory_diff = @import("memory_diff.zig");
const catch_up = @import("catch_up.zig");

/// What the two backends disagree on.
pub const What = union(enum) {
    register: diff.Mismatch,
    memory: memory_diff.Mismatch,

    pub fn write(self: What, out: anytype) !void {
        switch (self) {
            inline else => |found| try found.write(out),
        }
    }
};

pub const Divergence = struct {
    class: []const u8,
    instr: Instr,
    what: What,
    /// Both backends' registers after the instruction.
    ours: snapshot.Snapshot,
    oracle: snapshot.Snapshot,
};

pub const Result = union(enum) {
    /// Both agree after the instruction; the payload is its class.
    matched: []const u8,
    diverged: Divergence,
    /// The Zig core did not execute it. Unicorn was not stepped either, so
    /// the two still agree.
    stopped: cpu_mod.Stop,
    /// Unicorn cannot check this class, so only the Zig core ran it and
    /// Unicorn was brought to the same state; the payload is its class.
    skipped: []const u8,
    /// The Zig core executed it and Unicorn faulted on it.
    oracle_fault: engine.Fault,
};

pub fn one(ours: *cpu_mod.Cpu, theirs: engine.Engine) engine.Error!Result {
    const address = ours.regs.pc;
    const instr = Instr.fetch(ours.bus, address) catch {
        return .{ .stopped = .{ .bus_fault = address } };
    };
    const hit = decode.decode(instr);
    var made: writes.Recorder = .{ .inner = ours.bus };
    ours.bus = made.view();
    const stopped = ours.step();
    ours.bus = made.inner;
    if (stopped) |why| return .{ .stopped = why };
    const class = hit.?.group;
    if (!hit.?.oracle) {
        try catch_up.toZig(theirs, &ours.regs, made.items());
        return .{ .skipped = class };
    }
    if (try theirs.runChunk(address, 1, null)) |fault| return .{ .oracle_fault = fault };
    const mine = snapshot.Snapshot.fromRegs(&ours.regs);
    const other = try oracle.read(theirs);
    if (diff.first(mine, other)) |found| return diverged(class, instr, .{ .register = found }, mine, other);
    if (try memory_diff.first(made.items(), theirs)) |found| return diverged(class, instr, .{ .memory = found }, mine, other);
    return .{ .matched = class };
}

fn diverged(class: []const u8, instr: Instr, what: What, mine: snapshot.Snapshot, other: snapshot.Snapshot) Result {
    return .{ .diverged = .{ .class = class, .instr = instr, .what = what, .ours = mine, .oracle = other } };
}
