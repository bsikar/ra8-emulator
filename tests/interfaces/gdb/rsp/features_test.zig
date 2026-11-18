//! The target description and the windows qXfer reads it in, plus single-core
//! and dual-core GDB architecture and thread identity derived from Machine.
const std = @import("std");

const ra8 = @import("ra8");

const Cpu = ra8.chip.core.cpu.cpu.Cpu;
const dispatch = ra8.gdb.rsp.dispatch;
const elf = ra8.board.image.elf;
const features = ra8.gdb.rsp.features;
const machine_mod = ra8.chip.core.machine;
const memmap = ra8.chip.core.memmap;
const session_api = ra8.session.api;
const StopMachine = ra8.session.stop_machine.Machine;
const transport = ra8.session.transport;
const zig_run = dispatch.zig_run;
const zig_session = ra8.session.step_hook.zig.session;

test "a window short of the end is marked m, and the rest reads after it" {
    var out: [0x1000]u8 = undefined;
    const first = try features.read("target.xml:0,10", &out);
    try std.testing.expectEqual(@as(u8, 'm'), first[0]);
    try std.testing.expectEqualStrings(features.target_xml[0..0x10], first[1..]);
    var rest: [0x1000]u8 = undefined;
    const last = try features.read("target.xml:10,fff", &rest);
    try std.testing.expectEqual(@as(u8, 'l'), last[0]);
    try std.testing.expectEqualStrings(features.target_xml[0x10..], last[1..]);
}

test "a window past the end is an empty last window" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("l", try features.read("target.xml:ffff,10", &out));
}

test "an annex that is not target.xml, or numbers that do not parse, is E00" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("E00", try features.read("arm-core.xml:0,10", &out));
    try std.testing.expectEqualStrings("E00", try features.read("target.xml:zz,10", &out));
    try std.testing.expectEqualStrings("E00", try features.read("target.xml", &out));
}

// gdb checks these names to accept the M-profile feature.
test "the description names the M-profile feature and its seventeen registers" {
    const xml = features.target_xml;
    try std.testing.expect(std.mem.indexOf(u8, xml, "org.gnu.gdb.arm.m-profile") != null);
    try std.testing.expectEqual(@as(usize, 17), std.mem.count(u8, xml, "<reg "));
    try std.testing.expect(std.mem.indexOf(u8, xml, "name=\"xpsr\"") != null);
}

const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const reset_at: u32 = vectors + 0x40;
const stack: u32 = memmap.sram_base + 0x800;

const sole_m33: machine_mod.Machine = .{
    .name = "sole-m33",
    .label = "SOLE-M33",
    .cores = .{
        .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
        }),
    },
    .part = .ra8d2,
};

const sole_m85: machine_mod.Machine = .{
    .name = "sole-m85",
    .label = "SOLE-M85",
    .cores = .{
        .primary = machine_mod.core.cortexM85(.{
            .security = true,
            .fpu = .double,
            .systicks = 2,
        }),
    },
    .part = .ra8d2,
};

var wall_ns: u64 = 0;
fn wallNow(_: *anyopaque) u64 {
    wall_ns += 1_000_000;
    return wall_ns;
}

fn probeElf() [page * 2]u8 {
    var file: [page * 2]u8 align(@alignOf(elf.Header)) = @splat(0);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    head.* = .{
        .magic = .{ 0x7f, 'E', 'L', 'F' },
        .class = 1,
        .data = 1,
        .version = 1,
        .osabi = 0,
        .abiversion = 0,
        .pad = @splat(0),
        .e_type = 2,
        .e_machine = elf.em_arm,
        .e_version = 1,
        .e_entry = reset_at | 1,
        .e_phoff = @sizeOf(elf.Header),
        .e_shoff = 0,
        .e_flags = 0,
        .e_ehsize = @sizeOf(elf.Header),
        .e_phentsize = @sizeOf(elf.ProgramHeader),
        .e_phnum = 1,
        .e_shentsize = 0,
        .e_shnum = 0,
        .e_shstrndx = 0,
    };
    const ph: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    ph.* = .{
        .p_type = elf.pt_load,
        .p_offset = page,
        .p_vaddr = vectors,
        .p_paddr = vectors,
        .p_filesz = 0x100,
        .p_memsz = 0x100,
        .p_flags = 5,
        .p_align = 4,
    };
    std.mem.writeInt(u32, file[page..][0..4], stack, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], reset_at | 1, .little);
    const code = [_]u16{ 0x2001, 0x3002, 0x3003, 0xE7FE };
    for (code, 0..) |hw, i| {
        std.mem.writeInt(u16, file[page + 0x40 + i * 2 ..][0..2], hw, .little);
    }
    return file;
}

test "xmlFor selects armv8-m.main for M33 and armv8.1-m.main for M85 without MVE registers" {
    const m33_xml = features.xmlFor(sole_m33.cores.primary);
    try std.testing.expect(std.mem.indexOf(u8, m33_xml, "<architecture>armv8-m.main</architecture>") != null);
    try std.testing.expect(std.mem.indexOf(u8, m33_xml, "armv8.1-m.main") == null);
    try std.testing.expect(std.mem.indexOf(u8, m33_xml, "mve") == null);
    try std.testing.expectEqual(@as(usize, 17), std.mem.count(u8, m33_xml, "<reg "));

    const m85_xml = features.xmlFor(sole_m85.cores.primary);
    try std.testing.expect(std.mem.indexOf(u8, m85_xml, "<architecture>armv8.1-m.main</architecture>") != null);
    try std.testing.expectEqual(@as(usize, 17), std.mem.count(u8, m85_xml, "<reg "));
}

test "sole-M33 and sole-M85 GDB stubs report one thread, architecture XML, step, break and rewind" {
    try checkSingleCoreGdb(&sole_m33, "armv8-m.main", "CPU0 (Cortex-M33, armv8-m.main)");
    try checkSingleCoreGdb(&sole_m85, "armv8.1-m.main", "CPU0 (Cortex-M85, armv8.1-m.main)");
}

fn checkSingleCoreGdb(
    desc: *const machine_mod.Machine,
    arch: []const u8,
    extra_text: []const u8,
) !void {
    const bytes = probeElf();
    var h = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = &bytes,
        .machine = desc,
        .history_frames = 8,
    });
    defer h.deinit();
    var target: zig_run.Target = .{
        .session = h.session(),
        .wall = .{ .context = &wall_ns, .nowFn = wallNow },
    };
    const stub: dispatch.Dispatch = .{ .zig = &target };
    var out: [2048]u8 = undefined;

    const xml = try stub.answer("qXfer:features:read:target.xml:0,fff", &out);
    try std.testing.expectEqual(@as(u8, 'l'), xml[0]);
    try std.testing.expect(std.mem.indexOf(u8, xml[1..], arch) != null);

    try std.testing.expectEqualStrings("m1", try stub.answer("qfThreadInfo", &out));
    const extra_hex = try stub.answer("qThreadExtraInfo,1", &out);
    var decoded: [128]u8 = undefined;
    for (0..extra_hex.len / 2) |i| {
        decoded[i] = try std.fmt.parseInt(u8, extra_hex[i * 2 .. i * 2 + 2], 16);
    }
    try std.testing.expectEqualStrings(extra_text, decoded[0 .. extra_hex.len / 2]);
    try std.testing.expectEqualStrings("E00", try stub.answer("qThreadExtraInfo,2", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("Hg2", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("Hc2", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("T2", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("vCont;s:2", &out));

    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("s", &out));
    try std.testing.expectEqual(reset_at + 2, try h.session().register(.cpu0, .pc));
    try std.testing.expectEqualStrings("OK", try stub.answer("Z0,2000046,2", &out));
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("c", &out));
    try std.testing.expectEqual(reset_at + 6, try h.session().register(.cpu0, .pc));
    try std.testing.expectEqualStrings("06000000", try stub.answer("p0", &out));
    try std.testing.expectEqualStrings("T05thread:1;", try stub.answer("bs", &out));
    try std.testing.expectEqual(reset_at + 2, try h.session().register(.cpu0, .pc));
}

test "dual-core GDB switches target.xml architecture between CPU0 M85 and CPU1 M33" {
    const bus_mod = ra8.chip.core.cpu.bus;
    const Ram = struct {
        bytes: [64]u8 = .{ 0x40, 0, 0, 0, 0x09, 0, 0, 0, 0x00, 0xBF } ++ @as([54]u8, @splat(0)),
        fn view(self: *@This()) bus_mod.Bus {
            return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
        }
        fn read(ctx: *anyopaque, address: u32, into: []u8) bus_mod.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (address + into.len > self.bytes.len) return bus_mod.Error.Unmapped;
            @memcpy(into, self.bytes[address..][0..into.len]);
        }
        fn write(ctx: *anyopaque, address: u32, from: []const u8) bus_mod.Error!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (address + from.len > self.bytes.len) return bus_mod.Error.Unmapped;
            @memcpy(self.bytes[address..][0..from.len], from);
        }
    };
    var ram0: Ram = .{};
    var ram1: Ram = .{};
    var cpu0: Cpu = .{ .bus = ram0.view() };
    var cpu1: Cpu = .{ .bus = ram1.view() };
    try cpu0.reset(0);
    try cpu1.reset(0);
    var m0: StopMachine = .{};
    var m1: StopMachine = .{};
    var session: session_api.Session = .{
        .live = zig_session.ZigSession{
            .core = .{ .cpu = &cpu0 },
            .machine = &m0,
            .budget = 100,
            .other = .{ .core = .{ .cpu = &cpu1 }, .machine = &m1 },
        },
    };
    var target: zig_run.Target = .{
        .session = &session,
        .wall = transport.Wall{ .context = &wall_ns, .nowFn = wallNow },
    };
    const stub: dispatch.Dispatch = .{ .zig = &target };
    var out: [2048]u8 = undefined;

    try std.testing.expectEqualStrings("m1,2", try stub.answer("qfThreadInfo", &out));
    try std.testing.expectEqualStrings("", try stub.answer("qThreadExtraInfo,1", &out));
    const xml0 = try stub.answer("qXfer:features:read:target.xml:0,fff", &out);
    try std.testing.expect(std.mem.indexOf(u8, xml0, "<architecture>armv8.1-m.main</architecture>") != null);

    try std.testing.expectEqualStrings("OK", try stub.answer("Hg2", &out));
    const xml1 = try stub.answer("qXfer:features:read:target.xml:0,fff", &out);
    try std.testing.expect(std.mem.indexOf(u8, xml1, "<architecture>armv8-m.main</architecture>") != null);
}
