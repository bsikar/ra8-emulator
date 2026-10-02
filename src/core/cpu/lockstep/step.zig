//! One instruction on both backends, then a comparison of what each holds:
//! the registers, every store the Zig core made, and every peripheral access.
//!
//! Each backend needs its own memory, or a store by one would be read back
//! by the other and hide a divergence; the driver gives the Zig core an
//! engine of its own to fetch and store through. Peripherals are shared, so
//! Unicorn steps first and owns their side effects, and the Zig core's
//! peripheral accesses are replayed from what Unicorn did (periph_log.zig).
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
const periph_log = @import("periph_log.zig");

/// What the two backends disagree on.
pub const What = union(enum) {
    register: diff.Mismatch,
    memory: memory_diff.Mismatch,
    periph: periph_log.Mismatch,

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
    /// The Zig core did not execute it. For an encoding it does not know,
    /// Unicorn was not stepped either.
    stopped: cpu_mod.Stop,
    /// Unicorn cannot check this class, so only the Zig core ran it and
    /// Unicorn was brought to the same state; the payload is its class.
    skipped: []const u8,
    /// Unicorn faulted on it; the Zig core was not stepped.
    oracle_fault: engine.Fault,
};

/// `log` is the peripheral log Unicorn's tap writes into and the Zig core's
/// bus replays from; the caller wires both ends.
pub fn one(ours: *cpu_mod.Cpu, theirs: engine.Engine, log: *periph_log.Log) engine.Error!Result {
    const address = ours.regs.pc;
    const instr = Instr.fetch(ours.bus, address) catch {
        return .{ .stopped = .{ .bus_fault = address } };
    };
    const hit = decode.decode(instr);
    const checked = if (hit) |h| h.oracle else false;
    log.begin(checked);
    if (checked) {
        if (try theirs.runChunk(address, 1, null)) |fault| return .{ .oracle_fault = fault };
    }
    var made: writes.Recorder = .{ .inner = ours.bus };
    ours.bus = made.view();
    const stopped = ours.step();
    ours.bus = made.inner;
    log.armed = false;
    if (stopped) |why| return .{ .stopped = why };
    const class = hit.?.group;
    if (!checked) {
        try catch_up.toZig(theirs, &ours.regs, made.items());
        return .{ .skipped = class };
    }
    return compare(class, instr, ours, theirs, made.items(), log);
}

fn compare(class: []const u8, instr: Instr, ours: *cpu_mod.Cpu, theirs: engine.Engine, made: []const writes.Write, log: *const periph_log.Log) engine.Error!Result {
    const mine = snapshot.Snapshot.fromRegs(&ours.regs);
    const other = try oracle.read(theirs);
    if (diff.first(mine, other)) |found| return diverged(class, instr, .{ .register = found }, mine, other);
    if (try memory_diff.first(made, theirs)) |found| return diverged(class, instr, .{ .memory = found }, mine, other);
    if (log.verdict()) |found| return diverged(class, instr, .{ .periph = found }, mine, other);
    return .{ .matched = class };
}

fn diverged(class: []const u8, instr: Instr, what: What, mine: snapshot.Snapshot, other: snapshot.Snapshot) Result {
    return .{ .diverged = .{ .class = class, .instr = instr, .what = what, .ours = mine, .oracle = other } };
}
