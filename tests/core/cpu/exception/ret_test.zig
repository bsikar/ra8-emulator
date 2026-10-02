//! Covers src/core/cpu/exception/ret.zig, through whole instructions: SVC
//! into the handler and BX LR or POP {PC} back out.
const std = @import("std");
const ra8 = @import("ra8");
const regs = ra8.core.cpu.regs;
const fixture = @import("ram.zig");

const svc: u16 = 0xDF00;
const bx_lr: u16 = 0x4770;
const pop_pc: u16 = 0xBD00;

fn program(ram: *fixture.Ram, handler: u16) void {
    ram.putHalf(fixture.code, svc);
    ram.putHalf(fixture.code + 2, 0xBF00); // nop
    ram.putHalf(fixture.handler, handler);
}

test "SVC then BX LR comes back to the next instruction with everything restored" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.regs.low[2] = 0x22;
    cpu.regs.xpsr |= 0x2000_0000; // C
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.handler, cpu.regs.pc);
    try std.testing.expect(cpu.regs.handlerMode());
    cpu.regs.low[2] = 0xDEAD;
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expect(!cpu.regs.handlerMode());
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0x22), cpu.regs.low[2]);
    try std.testing.expectEqual(@as(u32, 0x2000_0000), cpu.regs.xpsr & 0xF800_0000);
    try std.testing.expectEqual(@as(?u32, null), cpu.regs.exc_return);
    try std.testing.expectEqual(@as(u64, 2), cpu.retired);
}

test "a realigned frame gives the stack back its odd word" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.regs.msp = fixture.msp_top - 4;
    _ = cpu.step();
    try std.testing.expectEqual(fixture.msp_top - 0x28, cpu.regs.msp);
    _ = cpu.step();
    try std.testing.expectEqual(fixture.msp_top - 4, cpu.regs.msp);
    try std.testing.expectEqual(@as(u32, 0), cpu.regs.xpsr & (1 << 9));
}

test "a return to the PSP restores it and selects it again" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    cpu.regs.psp = fixture.psp_top;
    cpu.regs.control |= regs.control_bits.spsel;
    _ = cpu.step();
    _ = cpu.step();
    try std.testing.expectEqual(fixture.psp_top, cpu.regs.psp);
    try std.testing.expect(cpu.regs.usesPsp());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
}

test "POP into the PC returns the same way" {
    var ram: fixture.Ram = .{};
    program(&ram, pop_pc);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    // The handler pushed LR; put it on the stack the way PUSH {LR} would.
    cpu.regs.msp -= 4;
    ram.putWord(cpu.regs.msp, cpu.regs.lr);
    try std.testing.expectEqual(@as(?ra8.core.cpu.cpu.Stop, null), cpu.step());
    try std.testing.expectEqual(fixture.code + 2, cpu.regs.pc);
    try std.testing.expectEqual(fixture.msp_top, cpu.regs.msp);
}

test "an EXC_RETURN the core cannot honour stops the core" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    cpu.regs.lr = 0xFFFF_FFE9; // FP frame
    try std.testing.expectEqual(fixture.handler, cpu.step().?.invalid_return);
}

test "a frame whose IPSR contradicts the return mode stops the core" {
    var ram: fixture.Ram = .{};
    program(&ram, bx_lr);
    var cpu = try fixture.boot(&ram);
    _ = cpu.step();
    cpu.regs.lr = 0xFFFF_FFF1; // Handler mode, but the frame came from Thread
    try std.testing.expectEqual(fixture.handler, cpu.step().?.invalid_return);
}

test "a branch to 0xFFxxxxxx in Thread mode is a plain branch" {
    var regs_file: regs.Regs = .{};
    regs_file.bxWritePc(0xFFFF_FFF9);
    try std.testing.expectEqual(@as(?u32, null), regs_file.exc_return);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF8), regs_file.pc);
}
