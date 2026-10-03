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
const oracle_writes = @import("oracle_writes.zig");
const fault_clear = @import("../../../periph/fault_clear.zig");
const catch_up = @import("catch_up.zig");
const periph_log = @import("periph_log.zig");
const std = @import("std");

const it_state = @import("../it_state.zig");

/// Unicorn runs an IT and its whole block as one step (QEMU translates them
/// together; checked with blocks of one, two and four instructions), so on a
/// compared IT the Zig core keeps stepping until the block is over before
/// the two are compared.
const it_class = "it";

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

/// A SecureFault the Zig core took on the instruction at `address`
/// (RA8EMU-396). Unicorn models no security state, so the two cannot be
/// compared from here on, and the run ends instead of counting a divergence.
pub const SecureFault = struct { address: u32 };

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
    /// The Zig core took a SecureFault on it, which Unicorn cannot model.
    secure_fault: SecureFault,
};

/// `log` is the peripheral log Unicorn's tap writes into and the Zig core's
/// bus replays from; the caller wires both ends. `settle` is the latch
/// Unicorn's fault-clear hook records into, settled after its step so a
/// write-one-to-clear lands within the instruction as it does on the Zig side.
pub fn one(ours: *cpu_mod.Cpu, theirs: engine.Engine, log: *periph_log.Log, settle: ?*fault_clear.Clears) engine.Error!Result {
    const address = ours.regs.pc;
    const instr = Instr.fetch(ours.bus, address) catch {
        return .{ .stopped = .{ .bus_fault = address } };
    };
    const hit = decode.decode(instr);
    const checked = if (hit) |h| h.oracle else false;
    log.begin(checked);
    var oracle_hook: oracle_writes.Hook = .{ .handle = theirs.handle, .hook = 0, .recorder = .{ .inner = undefined } };
    if (checked) {
        oracle_hook.attach() catch return engine.Error.AttachFailed;
    }
    defer oracle_hook.detach();
    if (checked) {
        if (try theirs.runChunk(address, 1, null)) |fault| return .{ .oracle_fault = fault };
        if (try retire(theirs, address)) |fault| return .{ .oracle_fault = fault };
        if (settle) |latch| latch.apply(theirs) catch return engine.Error.WriteFailed;
    }
    const faults = ours.secure_faults;
    var made: writes.Recorder = .{ .inner = ours.bus };
    ours.bus = made.view();
    var stopped = ours.step();
    if (stopped == null and checked and std.mem.eql(u8, hit.?.group, it_class)) stopped = finishBlock(ours);
    ours.bus = made.inner;
    log.armed = false;
    if (stopped) |why| return .{ .stopped = why };
    if (ours.secure_faults != faults) return .{ .secure_fault = .{ .address = address } };
    const class = hit.?.group;
    if (!checked) {
        try catch_up.toZig(theirs, &ours.regs, made.items());
        return .{ .skipped = class };
    }
    return compare(class, instr, ours, theirs, made.items(), if (checked) oracle_hook.recorder.items() else &.{}, log);
}

/// A Unicorn hook that ends the run inside an instruction leaves it landed
/// but the PC still on it: the SysTick arm store does (src/core/systick_hook.zig
/// stops on the store that starts the counter). One more step retires it.
/// The store goes in again with the same value, which the hook does not stop
/// on because the counter is already running; and an instruction that
/// really does stay put, `b .`, simply runs once more on Unicorn's side.
fn retire(theirs: engine.Engine, address: u32) engine.Error!?engine.Fault {
    const after = try oracle.read(theirs);
    if (after.get(.pc) != address) return null;
    return theirs.runChunk(address, 1, null);
}

/// Step the Zig core through the rest of an IT block; a block is at most
/// four instructions.
fn finishBlock(ours: *cpu_mod.Cpu) ?cpu_mod.Stop {
    for (0..4) |_| {
        if (!it_state.active(it_state.get(ours.regs.xpsr))) return null;
        if (ours.step()) |why| return why;
    }
    return null;
}

fn compare(class: []const u8, instr: Instr, ours: *cpu_mod.Cpu, theirs: engine.Engine, made: []const writes.Write, oracle_made: []const writes.Write, log: *const periph_log.Log) engine.Error!Result {
    const mine = snapshot.Snapshot.fromRegs(&ours.regs);
    const other = try oracle.read(theirs);
    if (diff.first(mine, other)) |found| return diverged(class, instr, .{ .register = found }, mine, other);
    if (try memory_diff.first(made, oracle_made, theirs, ours.bus)) |found| return diverged(class, instr, .{ .memory = found }, mine, other);
    if (log.verdict()) |found| return diverged(class, instr, .{ .periph = found }, mine, other);
    return .{ .matched = class };
}

fn diverged(class: []const u8, instr: Instr, what: What, mine: snapshot.Snapshot, other: snapshot.Snapshot) Result {
    return .{ .diverged = .{ .class = class, .instr = instr, .what = what, .ours = mine, .oracle = other } };
}
