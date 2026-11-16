//! Current firmware executes both authentication and launch; no crypto is replaced.
const std = @import("std");
const ra8 = @import("ra8");

const slots = ra8.session.boot_slots;
const layout = slots.layout;
const sci = ra8.chip.periph.sci;
const Harness = ra8.session.harness.Harness;
const symbols = ra8.session.symbols;
const api = ra8.session.api;

pub const signed_a = @embedFile("../fixtures/dfu/current/signed_a.bin");
pub const signed_b = @embedFile("../fixtures/dfu/current/signed_b.bin");
const wrong_root = @embedFile("../fixtures/dfu/current/wrong_root_b.bin");
pub const body_len = 32;
pub const marker_a: u32 = 0x9710_C0A1;
pub const marker_b: u32 = 0x9710_C0B2;
const marker_at = 0x2218_0000;
const chunk = 1_000_000;
const max_chunks = 200;

pub const Fault = enum { none, body, signature, wrong_root, version, magic, format_version, truncated, body_length, sig_length };
pub const Case = struct {
    fault_a: Fault = .none,
    fault_b: Fault = .none,
    seq_a: u32 = 1,
    seq_b: u32 = 2,
    trigger: bool = false,
};

const Console = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    fn sent(ctx: *anyopaque, channel: usize, byte: u8) void {
        const self: *Console = @ptrCast(@alignCast(ctx));
        if (channel != sci.console_channel or self.len == self.bytes.len) return;
        self.bytes[self.len] = byte;
        self.len += 1;
    }

    fn text(self: *const Console) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn stage(guest: anytype, which: slots.Which, fault: Fault, seq: u32) !void {
    const original = if (which == .a) signed_a else signed_b;
    var image: [signed_b.len]u8 = original[0..].*;
    switch (fault) {
        .none => {},
        .body => image[16] ^= 1, // Marker store precedes this heartbeat instruction.
        .signature => image[body_len + 52] ^= 1,
        .wrong_root => image = wrong_root[0..].*,
        .version => std.mem.writeInt(u32, image[body_len + 8 ..][0..4], 99, .little),
        .magic => image[body_len] ^= 1,
        .format_version => std.mem.writeInt(u32, image[body_len + 4 ..][0..4], 2, .little),
        .truncated => {},
        .body_length => std.mem.writeInt(u32, image[body_len + 12 ..][0..4], 64, .little),
        .sig_length => std.mem.writeInt(u32, image[body_len + 16 ..][0..4], 65, .little),
    }
    const base = slots.baseOf(which);
    const present = if (fault == .truncated) body_len + 84 else image.len;
    try guest.write(base, image[0..present]);
    const fields = [_]u32{
        layout.header_magic, seq, body_len, std.hash.Crc32.hash(image[0..body_len]), layout.run_base, 0, 0, 0,
    };
    var header: [layout.header_size]u8 = undefined;
    for (fields, 0..) |field, index| std.mem.writeInt(u32, header[index * 4 ..][0..4], field, .little);
    try guest.write(base + layout.header_offset, &header);
}

pub const Outcome = struct {
    gate_result: ?u16 = null,
    gate_slot: ?slots.Which = null,
    marker: u32 = 0,
    dfu: bool = false,
    crc_a: bool,
    crc_b: bool,
};

fn address(opened: *Harness, name: []const u8) !u32 {
    return (symbols.addressOf(opened.image(), name) orelse return error.MissingFirmwareSymbol) & ~@as(u32, 1);
}

fn until(opened: *Harness, console: *Console, pc: u32) !void {
    for (0..max_chunks) |_| {
        _ = try opened.session().run(.cpu0, .cont);
        if (opened.primaryCpu().regs.pc == pc) return;
        if (std.mem.indexOf(u8, console.text(), "entering DFU") != null) return;
        if (try opened.guest().readWord(marker_at) != 0) return;
    }
    std.debug.print("boot timeout pc=0x{x}\n{s}\n", .{ opened.primaryCpu().regs.pc, console.text() });
    return error.FirmwareBootTimeout;
}

pub fn boot(case: Case) !Outcome {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_path = "tests/fixtures/dfu/current/bootloader.elf",
        .files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops),
    });
    defer opened.deinit();
    const guest = opened.guest();
    try stage(guest, .a, case.fault_a, case.seq_a);
    try stage(guest, .b, case.fault_b, case.seq_b);
    const trigger = try address(&opened, layout.trigger_symbol);
    if (case.trigger) try guest.writeWord(trigger, layout.trigger_magic);
    const report = try slots.read(guest, trigger);
    var outcome: Outcome = .{ .crc_a = report.a.valid, .crc_b = report.b.valid };
    var console: Console = .{};
    opened.board().serial.tap = .{ .ctx = &console, .sent = Console.sent };
    const session = opened.session();
    session.live.budget = chunk;
    const verify = try address(&opened, "ra8_rot_verify_image");
    const gate_break = try session.setBreakpoint(.cpu0, .{ .address = verify });
    try until(&opened, &console, verify);
    try session.clearBreakpoint(.cpu0, gate_break);
    if (opened.primaryCpu().regs.pc == verify) {
        const source = try session.register(.cpu0, .r0);
        outcome.gate_slot = if (source == slots.baseOf(.a)) .a else if (source == slots.baseOf(.b)) .b else null;
        try std.testing.expectEqual(@as(u32, body_len), try session.register(.cpu0, .r1));
        const returned = (try session.register(.cpu0, .lr)) & ~@as(u32, 1);
        const return_break = try session.setBreakpoint(.cpu0, .{ .address = returned });
        try until(&opened, &console, returned);
        try std.testing.expectEqual(returned, opened.primaryCpu().regs.pc);
        outcome.gate_result = @truncate(try session.register(.cpu0, .r0));
        try session.clearBreakpoint(.cpu0, return_break);
        try until(&opened, &console, 0);
    }
    outcome.marker = try guest.readWord(marker_at);
    outcome.dfu = std.mem.indexOf(u8, console.text(), "no bootable slot -- entering DFU") != null;
    return outcome;
}
