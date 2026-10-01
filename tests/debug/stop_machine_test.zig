//! The run, step, step over, step out, continue and halt decisions.
const std = @import("std");
const ra8 = @import("ra8");
const stop_machine = ra8.core.stop_machine;
const Machine = stop_machine.Machine;
const Event = stop_machine.Event;

fn at(pc: u32) Event {
    return .{ .pc = pc, .size = 2, .sp = 0x2000_1000 };
}

fn isStepped(stop: ?stop_machine.Stop) bool {
    const got = stop orelse return false;
    return got == .stepped;
}

test "a halted session never stops the CPU" {
    var machine = Machine{};
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
}

test "a step runs the instruction it stopped on and stops on the next" {
    var machine = Machine{};
    machine.step();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
    try std.testing.expectEqual(stop_machine.Mode.halted, machine.mode);
}

test "running stops at a break and not before" {
    var machine = Machine{};
    const id = try machine.breaks.add(.{ .address = 0x108 });
    machine.proceed();
    for ([_]u32{ 0x100, 0x102, 0x104, 0x106 }) |pc| {
        try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(pc)));
    }
    const stop = machine.onInstruction(at(0x108)).?;
    try std.testing.expectEqual(id, stop.breakpoint);
}

test "continuing from a break runs past it instead of stopping again" {
    var machine = Machine{};
    _ = try machine.breaks.add(.{ .address = 0x108, .arrival = 2 });
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x108)));
    try std.testing.expect(machine.onInstruction(at(0x108)) != null);
    machine.proceed();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x108)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x10A)));
}

test "a step over a call runs the call and stops after it" {
    var machine = Machine{};
    machine.stepOver();
    const call = Event{ .pc = 0x100, .size = 4, .sp = 0x2000_1000, .call = true };
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(call));
    // Inside the callee, on a deeper frame.
    const inside = Event{ .pc = 0x400, .size = 2, .sp = 0x2000_0FF8 };
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(inside));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x104))));
}

test "a step over of a plain instruction is a single step" {
    var machine = Machine{};
    machine.stepOver();
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x100)));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
}

test "a break inside a stepped-over call still stops" {
    var machine = Machine{};
    const id = try machine.breaks.add(.{ .address = 0x400 });
    machine.stepOver();
    const call = Event{ .pc = 0x100, .size = 4, .sp = 0x2000_1000, .call = true };
    _ = machine.onInstruction(call);
    const stop = machine.onInstruction(.{ .pc = 0x400, .size = 2, .sp = 0x2000_0FF8 }).?;
    try std.testing.expectEqual(id, stop.breakpoint);
}

test "a step out stops on the return address at the caller's frame" {
    var machine = Machine{};
    machine.stepOut(0x205, 0x2000_0FF8);
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x400)));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x402)));
    const back = Event{ .pc = 0x204, .size = 2, .sp = 0x2000_1000 };
    try std.testing.expect(isStepped(machine.onInstruction(back)));
}

test "a step out ignores the same return address on a deeper recursive frame" {
    var machine = Machine{};
    machine.stepOut(0x204, 0x2000_0FF0);
    _ = machine.onInstruction(at(0x400));
    const deeper = Event{ .pc = 0x204, .size = 2, .sp = 0x2000_0FE0 };
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(deeper));
    const caller = Event{ .pc = 0x204, .size = 2, .sp = 0x2000_0FF0 };
    try std.testing.expect(isStepped(machine.onInstruction(caller)));
}

test "a halt request stops a running session before its next instruction" {
    var machine = Machine{};
    machine.proceed();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expectEqual(@as(?stop_machine.Stop, null), machine.onInstruction(at(0x102)));
    machine.requestHalt();
    const stop = machine.onInstruction(at(0x104)).?;
    try std.testing.expect(stop == .halt_requested);
    try std.testing.expectEqual(stop_machine.Mode.halted, machine.mode);
}

test "a halt request on a halted session is dropped" {
    var machine = Machine{};
    machine.requestHalt();
    machine.step();
    _ = machine.onInstruction(at(0x100));
    try std.testing.expect(isStepped(machine.onInstruction(at(0x102))));
}
