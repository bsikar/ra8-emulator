//! Boot-slot reader for the ra8-firmware dfu_bootloader A/B layout: reads
//! both slot headers out of guest MRAM, recomputes each body's CRC, and
//! applies the bootloader's own decision, so the debugger can say which
//! slot boots (or that the board stays in USB-DFU) without running it.
//!
//! The layout and the rules are copied, once, from ra8-firmware
//! libs/ra8_dfu: inc/ra8_dfu.h (addresses and magics),
//! src/internal/image.zig (header, length rule, run base),
//! src/internal/slot.zig (select and decide) and src/internal/crc32.zig
//! (IEEE CRC32, the same one std.hash.Crc32 computes). Change them there
//! first, then here.
const std = @import("std");

pub const layout = struct {
    pub const mram_base: u32 = 0x0200_0000;
    pub const bootloader_size: u32 = 0x0002_0000;
    pub const slot_a_base: u32 = 0x0202_0000;
    pub const slot_b_base: u32 = 0x0209_0000;
    pub const slot_size: u32 = 0x0007_0000;
    pub const page_size: u32 = 0x0000_0020;
    pub const header_size: u32 = 0x0000_0020;
    /// The header is the slot's last page, so the body starts at the base.
    pub const header_offset: u32 = slot_size - header_size;
    pub const image_max: u32 = slot_size - header_size;
    /// "RA8D".
    pub const header_magic: u32 = 0x5241_3844;
    pub const trigger_magic: u32 = 0xDF00_B007;
    /// Copy-to-run base: the bootloader copies the chosen body here.
    pub const run_base: u32 = 0x2202_0000;
    /// The `.noinit` word an application sets to ask for DFU. It is a
    /// static, so its address comes from the image's symbols, per build.
    pub const trigger_symbol = "g_dfu_trigger";
};

pub const Which = enum { a, b };
pub const Action = enum { dfu, boot_a, boot_b };
pub const Trigger = enum { unknown, clear, set };

pub const Header = struct {
    magic: u32,
    seq: u32,
    img_len: u32,
    img_crc32: u32,
    entry: u32,
};

pub const Slot = struct {
    which: Which,
    base: u32,
    header: Header,
    magic_ok: bool,
    length_ok: bool,
    /// CRC32 recomputed over `img_len` body bytes; null when the length is
    /// out of range, since then there is no body to check.
    crc: ?u32,
    /// The firmware's headerValid: magic, length and CRC all agree.
    valid: bool,
    /// The header's entry is the run base the bootloader copies to.
    entry_ok: bool,
};

pub const Report = struct {
    a: Slot,
    b: Slot,
    trigger: Trigger,
    action: Action,
    run_base: u32,

    /// The slot the bootloader would copy to `run_base` and start, if any.
    pub fn booted(self: *const Report) ?*const Slot {
        return switch (self.action) {
            .boot_a => &self.a,
            .boot_b => &self.b,
            .dfu => null,
        };
    }
};

pub fn baseOf(which: Which) u32 {
    return switch (which) {
        .a => layout.slot_a_base,
        .b => layout.slot_b_base,
    };
}

pub fn lengthValid(img_len: u32) bool {
    return img_len != 0 and img_len <= layout.image_max and img_len % layout.page_size == 0;
}

/// Reads both slots and the trigger through `source`, anything with
/// `read(address: u32, into: []u8) !void` over guest memory. With no
/// `trigger_address` the trigger is `.unknown` and decided as clear.
pub fn read(source: anytype, trigger_address: ?u32) !Report {
    const a = try readSlot(source, .a);
    const b = try readSlot(source, .b);
    const trigger = try readTrigger(source, trigger_address);
    return .{
        .a = a,
        .b = b,
        .trigger = trigger,
        .action = decide(trigger == .set, a, b),
        .run_base = layout.run_base,
    };
}

/// The bootloader's rule: a trigger or no valid slot means DFU; otherwise
/// the valid slot with the higher sequence boots, Slot A on a tie.
pub fn decide(trigger: bool, a: Slot, b: Slot) Action {
    if (trigger) return .dfu;
    if (!a.valid and !b.valid) return .dfu;
    if (a.valid and (!b.valid or a.header.seq >= b.header.seq)) return .boot_a;
    return .boot_b;
}

pub fn readSlot(source: anytype, which: Which) !Slot {
    const base = baseOf(which);
    var raw: [layout.header_size]u8 = undefined;
    try source.read(base + layout.header_offset, &raw);
    const header = Header{
        .magic = word(&raw, 0),
        .seq = word(&raw, 1),
        .img_len = word(&raw, 2),
        .img_crc32 = word(&raw, 3),
        .entry = word(&raw, 4),
    };
    const magic_ok = header.magic == layout.header_magic;
    const length_ok = lengthValid(header.img_len);
    const crc: ?u32 = if (length_ok) try bodyCrc(source, base, header.img_len) else null;
    return .{
        .which = which,
        .base = base,
        .header = header,
        .magic_ok = magic_ok,
        .length_ok = length_ok,
        .crc = crc,
        .valid = magic_ok and crc != null and crc.? == header.img_crc32,
        .entry_ok = header.entry == layout.run_base,
    };
}

fn readTrigger(source: anytype, address: ?u32) !Trigger {
    const at = address orelse return .unknown;
    var raw: [4]u8 = undefined;
    try source.read(at, &raw);
    return if (word(&raw, 0) == layout.trigger_magic) .set else .clear;
}

fn bodyCrc(source: anytype, base: u32, len: u32) !u32 {
    var crc = std.hash.Crc32.init();
    var chunk: [1024]u8 = undefined;
    var done: u32 = 0;
    while (done < len) {
        const n: u32 = @min(len - done, chunk.len);
        try source.read(base + done, chunk[0..n]);
        crc.update(chunk[0..n]);
        done += n;
    }
    return crc.final();
}

fn word(raw: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, raw[index * 4 ..][0..4], .little);
}
