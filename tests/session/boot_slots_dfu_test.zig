//! RA8EMU-776: the real dfu_bootloader picks between staged slots the way
//! boot_slots says it will. tests/fixtures/dfu/README.md has the provenance.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const boot_slots = ra8.session.boot_slots;
const layout = boot_slots.layout;
const sci = ra8.chip.periph.sci;

const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";
const signed_a = @embedFile("../fixtures/dfu/signed_a.bin");
const signed_b = @embedFile("../fixtures/dfu/signed_b.bin");

/// The payload body both slots carry; the ROT1 trailer follows it.
const payload_len: u32 = 32;
const trigger_at: u32 = 0x220F_FF00;
const sentinel_at: u32 = 0x2201_0000;
const sentinel: u32 = 0x9710_C0DE;
const chunk: u64 = 1_000_000;
const max_chunks = 200;

const Console = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,

    fn sent(ctx: *anyopaque, channel: usize, byte: u8) void {
        const self: *Console = @ptrCast(@alignCast(ctx));
        if (channel != sci.console_channel or self.len == self.bytes.len) return;
        self.bytes[self.len] = byte;
        self.len += 1;
    }

    fn tap(self: *Console) sci.Tap {
        return .{ .ctx = self, .sent = sent };
    }

    fn text(self: *const Console) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Corrupt = enum { none, b_crc };

fn stage(guest: anytype, which: boot_slots.Which, image: []const u8, seq: u32, corrupt: bool) !void {
    const base = boot_slots.baseOf(which);
    try guest.write(base, image);
    var crc = std.hash.Crc32.hash(image[0..payload_len]);
    if (corrupt) crc ^= 1;
    const fields = [_]u32{ layout.header_magic, seq, payload_len, crc, layout.run_base, 0, 0, 0 };
    var raw: [layout.header_size]u8 = undefined;
    for (fields, 0..) |field, i| std.mem.writeInt(u32, raw[i * 4 ..][0..4], field, .little);
    try guest.write(base + layout.header_offset, &raw);
}

const Outcome = struct {
    report: boot_slots.Report,
    ran: bool,
};

fn boot(console: *Console, corrupt: Corrupt) !Outcome {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = elf_path });
    defer opened.deinit();
    const guest = opened.guest();
    try stage(guest, .a, signed_a, 1, false);
    try stage(guest, .b, signed_b, 2, corrupt == .b_crc);
    const report = try boot_slots.read(guest, trigger_at);
    opened.board().serial.tap = console.tap();
    const session = opened.session();
    session.live.budget = chunk;
    var ran = false;
    for (0..max_chunks) |_| {
        _ = try session.run(.cpu0, .cont);
        var word: [4]u8 = undefined;
        try guest.read(sentinel_at, &word);
        ran = std.mem.readInt(u32, &word, .little) == sentinel;
        if (ran) break;
    }
    return .{ .report = report, .ran = ran };
}

test "the newer valid slot boots and runs its payload" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    var console = Console{};
    const outcome = try boot(&console, .none);
    try std.testing.expectEqual(boot_slots.Action.boot_b, outcome.report.action);
    try std.testing.expect(outcome.ran);
    try std.testing.expect(std.mem.indexOf(u8, console.text(), "Slot B") != null);
}

test "a bad CRC on the newer slot falls back to Slot A" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    var console = Console{};
    const outcome = try boot(&console, .b_crc);
    try std.testing.expect(!outcome.report.b.valid);
    try std.testing.expectEqual(boot_slots.Action.boot_a, outcome.report.action);
    try std.testing.expect(outcome.ran);
    try std.testing.expect(std.mem.indexOf(u8, console.text(), "Slot A") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.text(), "Slot B ->") == null);
}

/// The session-level clause of the pure-reads slice (RA8EMU-1120): the real
/// DFU device enumerates on the device jack while the core sleeps, and the
/// landing is the same with idle skip on or off and with the debugger
/// inspecting through the quiet read path or not. Corrupting both slots keeps
/// the bootloader in DFU mode instead of booting a payload.
const enum_chunks = 12;

const Landing = struct {
    step: usize,
    quiet: bool,
    syscfg: u32,
    intsts0: u32,
};

/// A debugger read of the USBFS window through the session's view: the
/// debugger path peeks before it reads, so inspection never stirs the device.
fn readWindow(view: anytype, offset: u32) !u32 {
    var word: [4]u8 = undefined;
    try view.read(0x4025_0000 + offset, &word);
    return std.mem.readInt(u32, &word, .little);
}

fn enumerate(skip: bool, inspect: bool) !Landing {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = elf_path, .idle_skip = skip });
    defer opened.deinit();
    opened.board().usb.device.connectVbus();
    const guest = opened.guest();
    try stage(guest, .a, signed_a, 1, true);
    try stage(guest, .b, signed_b, 2, true);
    const session = opened.session();
    session.live.budget = chunk;
    const view = session.live.view();
    for (0..enum_chunks) |_| {
        _ = try session.run(.cpu0, .cont);
        if (inspect) {
            _ = try readWindow(view, 0);
            _ = try readWindow(view, 4);
        }
    }
    return .{
        .step = @backingInt(opened.board().usb.script.step),
        .quiet = opened.board().usb.quiet(),
        .syscfg = try readWindow(view, 0),
        .intsts0 = try readWindow(view, 4),
    };
}

test "the DFU device enumerates to the same landing with idle skip on and off, inspected and not" {
    if (builtin.mode != .fast) return error.SkipZigTest;
    const expected = try enumerate(true, false);
    try std.testing.expect(expected.quiet);
    inline for (.{ .{ true, true }, .{ false, false }, .{ false, true } }) |combo| {
        const got = try enumerate(combo[0], combo[1]);
        try std.testing.expectEqual(expected, got);
    }
}
