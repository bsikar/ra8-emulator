//! Covers src/core/long_shift_hook.zig with a live Unicorn: the hook has to
//! run before the CPU model's ORRS, land the Armv8.1-M result, set Q on a
//! clamp, and let the run carry on from the next instruction.
const std = @import("std");
const ra8 = @import("ra8");
const engine = ra8.core.engine;
const elf = ra8.core.elf;
const hook = engine.long_shift_hook;

const base: u32 = 0x2200_0000;
const q_bit: u32 = 1 << 27;

/// lsll r2, r3, #2 / movs r0, #1 / bkpt.
const shift_then_move = [_]u8{ 0x52, 0xEA, 0x8F, 0x03, 0x01, 0x20, 0x00, 0xBE };
/// uqshll r2, r3, #5 / bkpt.
const saturate = [_]u8{ 0x53, 0xEA, 0x4F, 0x13, 0x00, 0xBE };
/// asrl r2, r3, r12 / bkpt.
const by_register = [_]u8{ 0x52, 0xEA, 0x2D, 0xC3, 0x00, 0xBE };

fn coreWith(code: []const u8) !engine.Engine {
    var core = try engine.Engine.open();
    errdefer core.close();
    try core.map(base, 0x1000);
    try core.write(base, code);
    try hook.hookAt(core.handle, base);
    return core;
}

test "lsll runs as a long shift and the run carries on past it" {
    var core = try coreWith(&shift_then_move);
    defer core.close();
    try core.setRegister(.r2, 0xC000_0001);
    try core.setRegister(.r3, 0x0000_0001);
    try core.setRegister(.r0, 0);
    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0x0000_0004), try core.register(.r2));
    try std.testing.expectEqual(@as(u32, 0x0000_0007), try core.register(.r3));
    // The movs after it ran, so the PC moved on rather than repeating.
    try std.testing.expectEqual(@as(u32, 1), try core.register(.r0));
}

test "a saturating clamp sets Q" {
    var core = try coreWith(&saturate);
    defer core.close();
    try core.setRegister(.r2, 0);
    try core.setRegister(.r3, 0x0800_0000);
    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try core.register(.r2));
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFFF), try core.register(.r3));
    try std.testing.expect(try core.register(.xpsr) & q_bit != 0);
}

test "the register form reads Rm out of the core" {
    var core = try coreWith(&by_register);
    defer core.close();
    try core.setRegister(.r2, 0);
    try core.setRegister(.r3, 0x8000_0000);
    try core.setRegister(.r12, 4);
    _ = try core.run(base, 16, .{});
    try std.testing.expectEqual(@as(u32, 0xF800_0000), try core.register(.r3));
    try std.testing.expectEqual(@as(u32, 4), try core.register(.r12));
}

/// An ELF32 ARM image carrying one executable segment of the given bytes.
fn imageWith(buffer: []u8, code: []const u8, vaddr: u32) elf.Image {
    @memset(buffer, 0);
    const head = std.mem.bytesAsValue(elf.Header, buffer[0..@sizeOf(elf.Header)]);
    @memcpy(&head.magic, "\x7fELF");
    head.class = 1;
    head.data = 1;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 1;
    const at = @as(usize, head.e_phoff);
    const ph = std.mem.bytesAsValue(elf.ProgramHeader, buffer[at..][0..@sizeOf(elf.ProgramHeader)]);
    ph.p_type = elf.pt_load;
    ph.p_flags = elf.pf_x;
    ph.p_offset = @intCast(at + @sizeOf(elf.ProgramHeader));
    ph.p_vaddr = vaddr;
    ph.p_paddr = vaddr;
    ph.p_filesz = @intCast(code.len);
    ph.p_memsz = @intCast(code.len);
    @memcpy(buffer[ph.p_offset..][0..code.len], code);
    return elf.Image.init(buffer) catch unreachable;
}

test "attach hooks every long shift in an executable segment and nothing else" {
    // mov r0, r2 / lsll r2, r3, #2 / asrl r2, r3, r12 / orr.w r3, r3, r2, lsr #30
    const code = [_]u8{ 0x10, 0x46, 0x52, 0xEA, 0x8F, 0x03, 0x52, 0xEA, 0x2D, 0xC3, 0x43, 0xEA, 0x92, 0x73 };
    var buffer: [256]u8 = undefined;
    var core = try engine.Engine.open();
    defer core.close();
    try std.testing.expectEqual(@as(usize, 2), try hook.attach(core.handle, imageWith(&buffer, &code, base)));
}
