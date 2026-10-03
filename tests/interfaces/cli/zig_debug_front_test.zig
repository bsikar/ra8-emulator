//! Tests for src/interfaces/cli/zig_debug_front.zig: a `--cpu zig
//! --debug-script` command line reaches the Zig core's debugger and plays
//! the script against a real image.
const std = @import("std");
const ra8 = @import("ra8");

const debug_front = ra8.core.debug_front;
const zig_debug_front = ra8.core.step_hook.zig_debug_front;
const elf = ra8.core.elf;
const memmap = ra8.core.memmap;

/// The program tests/debug/zig_script_test.zig uses: a vector table at
/// sram_base, reset at +0x18, a loop calling a helper at +0x8.
const program = struct {
    const base: u32 = memmap.sram_base;
    const bytes = [_]u8{
        0x00, 0x00, 0x01, 0x22, 0x19, 0x00, 0x00, 0x22, 0x02, 0x49, 0x0a, 0x68, 0x10,
        0x44, 0x08, 0x60, 0x70, 0x47, 0x00, 0xbf, 0x54, 0x00, 0x00, 0x22, 0x10, 0xb5,
        0x00, 0x24, 0x05, 0x2c, 0x04, 0xd0, 0x20, 0x46, 0xff, 0xf7, 0xf1, 0xff, 0x01,
        0x34, 0xf8, 0xe7, 0x01, 0x20, 0xff, 0xf7, 0xec, 0xff, 0xfb, 0xe7, 0x70, 0x47,
    };
};

/// An ELF32 ARM image with one executable load segment holding `program`.
fn build(buffer: []u8) []u8 {
    @memset(buffer, 0);
    const header_len = @sizeOf(elf.Header);
    const ph_len = @sizeOf(elf.ProgramHeader);
    const code_off = header_len + ph_len;
    const head: *align(1) elf.Header = std.mem.bytesAsValue(elf.Header, buffer[0..header_len]);
    head.magic = .{ 0x7F, 'E', 'L', 'F' };
    head.class = 1;
    head.data = 1;
    head.version = 1;
    head.e_type = 2;
    head.e_machine = elf.em_arm;
    head.e_version = 1;
    head.e_entry = program.base + 0x19;
    head.e_phoff = header_len;
    head.e_ehsize = header_len;
    head.e_phentsize = ph_len;
    head.e_phnum = 1;
    const ph: *align(1) elf.ProgramHeader = std.mem.bytesAsValue(elf.ProgramHeader, buffer[header_len..][0..ph_len]);
    ph.* = .{ .p_type = elf.pt_load, .p_offset = code_off, .p_vaddr = program.base, .p_paddr = program.base, .p_filesz = program.bytes.len, .p_memsz = program.bytes.len, .p_flags = elf.pf_x | 4, .p_align = 4 };
    @memcpy(buffer[code_off..][0..program.bytes.len], &program.bytes);
    return buffer[0 .. code_off + program.bytes.len];
}

test "--cpu zig is taken anywhere on a debugger command line" {
    const after = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu", "zig", "--debug-script", "s.gdb" }).?;
    try std.testing.expectEqual(.zig, after.cpu);
    try std.testing.expectEqualStrings("fw.elf", after.image);
    try std.testing.expectEqualStrings("s.gdb", after.mode.script);
    const before = try debug_front.wanted(&.{ "ra8_emulator", "--cpu", "zig", "fw.elf", "--debug" }).?;
    try std.testing.expectEqual(.zig, before.cpu);
    try std.testing.expectEqualStrings("fw.elf", before.image);
    const last = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--gdb", "3333", "--cpu", "zig" }).?;
    try std.testing.expectEqual(.zig, last.cpu);
    try std.testing.expectEqual(@as(u16, 3333), last.mode.gdb);
    const plain = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--debug" }).?;
    try std.testing.expectEqual(.unicorn, plain.cpu);
}

test "an unknown --cpu is bad usage for the debugger and left alone for a run" {
    try std.testing.expectError(error.BadUsage, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu", "z80", "--debug" }).?);
    try std.testing.expectEqual(null, debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu", "z80" }));
}

test "--gdb runs on the Zig core; what its debugger does not take yet says so" {
    try std.testing.expectEqual(null, zig_debug_front.refusal(.{ .mode = .interactive, .cpu = .zig }));
    try std.testing.expectEqual(null, zig_debug_front.refusal(.{ .mode = .{ .gdb = 1 }, .cpu = .zig }));
    try std.testing.expectEqual(null, zig_debug_front.refusal(.{ .mode = .interactive, .cpu = .zig, .cpu1 = "c.elf" }));
    try std.testing.expectEqual(null, zig_debug_front.refusal(.{ .mode = .{ .gdb = 1 }, .cpu = .zig, .cpu1 = "c.elf" }));
    try std.testing.expect(zig_debug_front.refusal(.{ .mode = .interactive, .cpu = .lockstep }) != null);
}

test "a --cpu zig --debug-script command line plays the script on the Zig core" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "s.gdb", .data = "break 0x22000008\nrun\nbt\nquit\n" });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/tmp/{s}/s.gdb", .{tmp.sub_path});
    const request = try debug_front.wanted(&.{ "ra8_emulator", "fw.elf", "--cpu", "zig", "--debug-script", path }).?;
    var buffer: [256]u8 = undefined;
    const image = try elf.Image.init(build(&buffer));
    var out = std.ArrayList(u8).init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectEqual(@as(u8, 0), try zig_debug_front.run(std.testing.allocator, image, request, out.writer()));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "(ra8) run\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Breakpoint 1, 0x22000008") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "(ra8) bt\n#0") != null);
}
