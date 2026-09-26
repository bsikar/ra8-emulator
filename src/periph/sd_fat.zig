//! The bytes a FAT volume opens with: the BIOS Parameter Block, the FSInfo
//! sector, and the first entries of the FAT itself.
//!
//! Vocabulary and serialisation only, the shape sd_reply.zig and
//! eink_wire.zig take beside the protocol files they serve: what a field is
//! called, where it sits in the sector, and how a value gets into it. Which
//! geometry a card is given, and which volumes are refused outright, is
//! sd_format.zig's business.
//!
//! Ported from board_periph_sd_format.c on dev, whose field table this keeps.
//! dev's own literals live in a private header this port does not carry, so
//! every value here is the one the FAT specification gives, and the two that
//! are nobody's but this model's (the serial-number seed and the OEM string)
//! say so where they are declared.
const std = @import("std");
const image = @import("sd_image.zig");

/// One sector, which on every card this tree models is one block.
pub const Sector = image.Block;
pub const sector_bytes: usize = image.geometry.block_bytes;

/// What a solved volume looks like on the card. Filled in by sd_format.zig,
/// read here to lay the sectors out.
pub const Layout = struct {
    total_sectors: u32,
    sectors_per_cluster: u32,
    reserved_sectors: u32,
    fat_sectors: u32,
    root_sectors: u32,
    clusters: u32,
};

/// Where each shared BPB field sits in the boot sector. FAT16 and FAT32 agree
/// as far as byte 36 and part ways after it, so the two extended sets are
/// named apart rather than folded together.
pub const offset = struct {
    pub const jump: usize = 0;
    pub const oem: usize = 3;
    pub const bytes_per_sector: usize = 11;
    pub const sectors_per_cluster: usize = 13;
    pub const reserved_sectors: usize = 14;
    pub const fats: usize = 16;
    pub const root_entries: usize = 17;
    pub const total_sectors16: usize = 19;
    pub const media: usize = 21;
    pub const fat_sectors16: usize = 22;
    pub const sectors_per_track: usize = 24;
    pub const heads: usize = 26;
    pub const total_sectors32: usize = 32;
    pub const signature: usize = 510;
};

/// The fields only a FAT16 boot sector carries.
pub const offset16 = struct {
    pub const drive: usize = 36;
    pub const boot_signature: usize = 38;
    pub const volume_id: usize = 39;
    pub const label: usize = 43;
    pub const fs_type: usize = 54;
};

/// The fields only a FAT32 boot sector carries.
pub const offset32 = struct {
    pub const fat_sectors32: usize = 36;
    pub const root_cluster: usize = 44;
    pub const fs_info: usize = 48;
    pub const backup_boot: usize = 50;
    pub const drive: usize = 64;
    pub const boot_signature: usize = 66;
    pub const volume_id: usize = 67;
    pub const label: usize = 71;
    pub const fs_type: usize = 82;
};

/// Where the FSInfo sector keeps its four fields.
pub const fsinfo_offset = struct {
    pub const lead: usize = 0;
    pub const structure: usize = 484;
    pub const free_clusters: usize = 488;
    pub const next_free: usize = 492;
    pub const trail: usize = 508;
};

/// The values those fields take.
pub const value = struct {
    /// JMP SHORT +0x58 / NOP, the prologue a boot sector opens with.
    pub const jump: [3]u8 = .{ 0xEB, 0x58, 0x90 };
    /// Exactly eight bytes, the width of the field.
    pub const oem: *const [8]u8 = "MSDOS5.0";
    pub const signature: [2]u8 = .{ 0x55, 0xAA };
    pub const media_fixed: u8 = 0xF8;
    pub const sectors_per_track: u16 = 63;
    pub const heads: u16 = 255;
    pub const drive: u8 = 0x80;
    pub const extended_boot_signature: u8 = 0x29;
    /// The serial number is this seed or'd with the sector count, so a card
    /// of a given size always comes up with the same one. The seed is this
    /// model's own: dev's lives in a header this port does not carry.
    pub const volume_id_seed: u32 = 0x5241_0000;
    pub const fs_type16: *const [8]u8 = "FAT16   ";
    pub const fs_type32: *const [8]u8 = "FAT32   ";
    pub const root_cluster: u32 = 2;
    /// FAT16 entry 0 carries the media byte, entry 1 ends the chain.
    pub const fat16_entry0: u16 = 0xFFF8;
    pub const fat16_entry1: u16 = 0xFFFF;
    pub const fat32_entry0: u32 = 0x0FFF_FFF8;
    pub const fat32_end_of_chain: u32 = 0x0FFF_FFFF;
    pub const fsinfo_lead: u32 = 0x4161_5252;
    pub const fsinfo_structure: u32 = 0x6141_7272;
    pub const fsinfo_trail: u32 = 0xAA55_0000;
    /// The first cluster a driver may hand out: the root holds cluster 2.
    pub const first_free_cluster: u32 = 3;
    /// The widest sector count the 16-bit field can carry.
    pub const total_sectors16_max: u32 = 0x1_0000;
};

/// The 8.3 volume-label field is eleven bytes wide and space-padded.
pub const label_len: usize = 11;

pub const LabelError = error{BadLabel};

/// Put a label in its field. A label longer than the field, or carrying a
/// byte an 8.3 name cannot hold, is refused rather than truncated or copied
/// through; a lowercase letter is stored uppercased, which is what a real
/// format does with one.
pub fn labelField(dst: *[label_len]u8, label: []const u8) LabelError!void {
    if (label.len > label_len) return error.BadLabel;
    dst.* = .{' '} ** label_len;
    for (label, 0..) |byte, index| {
        if (!labelByteAllowed(byte)) return error.BadLabel;
        dst[index] = std.ascii.toUpper(byte);
    }
}

/// Whether one byte may appear in a short name: printable ASCII, less the
/// characters the field reserves for paths and wildcards.
fn labelByteAllowed(byte: u8) bool {
    if (byte < 0x20 or byte >= 0x7F) return false;
    return std.mem.indexOfScalar(u8, "\"*+,./:;<=>?[\\]|", byte) == null;
}

pub fn put16(buf: *Sector, at: usize, v: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], v, .little);
}

pub fn put32(buf: *Sector, at: usize, v: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], v, .little);
}

/// The prologue and trailing signature every boot sector carries, whatever
/// FAT width follows.
fn bootFrame(buf: *Sector) void {
    @memcpy(buf[offset.jump..][0..value.jump.len], &value.jump);
    @memcpy(buf[offset.oem..][0..value.oem.len], value.oem);
    @memcpy(buf[offset.signature..][0..value.signature.len], &value.signature);
}

/// The geometry both widths state the same way.
fn commonBpb(buf: *Sector, layout: Layout) void {
    bootFrame(buf);
    put16(buf, offset.bytes_per_sector, @intCast(sector_bytes));
    buf[offset.sectors_per_cluster] = @intCast(layout.sectors_per_cluster);
    put16(buf, offset.reserved_sectors, @intCast(layout.reserved_sectors));
    buf[offset.media] = value.media_fixed;
    put16(buf, offset.sectors_per_track, value.sectors_per_track);
    put16(buf, offset.heads, value.heads);
}

/// A FAT16 boot sector for `layout`.
pub fn bootSector16(layout: Layout, fats: u32, label: []const u8) LabelError!Sector {
    var buf: Sector = .{0} ** sector_bytes;
    commonBpb(&buf, layout);
    buf[offset.fats] = @intCast(fats);
    put16(&buf, offset.root_entries, @intCast(layout.root_sectors * sector_bytes / 32));
    if (layout.total_sectors < value.total_sectors16_max) {
        put16(&buf, offset.total_sectors16, @intCast(layout.total_sectors));
    } else {
        put32(&buf, offset.total_sectors32, layout.total_sectors);
    }
    put16(&buf, offset.fat_sectors16, @intCast(layout.fat_sectors));
    buf[offset16.drive] = value.drive;
    buf[offset16.boot_signature] = value.extended_boot_signature;
    put32(&buf, offset16.volume_id, value.volume_id_seed | layout.total_sectors);
    try labelField(buf[offset16.label..][0..label_len], label);
    @memcpy(buf[offset16.fs_type..][0..value.fs_type16.len], value.fs_type16);
    return buf;
}

/// A FAT32 boot sector for `layout`.
pub fn bootSector32(layout: Layout, fats: u32, label: []const u8) LabelError!Sector {
    var buf: Sector = .{0} ** sector_bytes;
    commonBpb(&buf, layout);
    buf[offset.fats] = @intCast(fats);
    put32(&buf, offset.total_sectors32, layout.total_sectors);
    put32(&buf, offset32.fat_sectors32, layout.fat_sectors);
    put32(&buf, offset32.root_cluster, value.root_cluster);
    put16(&buf, offset32.fs_info, @intCast(fsinfo_sector));
    put16(&buf, offset32.backup_boot, @intCast(backup_sector));
    buf[offset32.drive] = value.drive;
    buf[offset32.boot_signature] = value.extended_boot_signature;
    put32(&buf, offset32.volume_id, value.volume_id_seed | layout.total_sectors);
    try labelField(buf[offset32.label..][0..label_len], label);
    @memcpy(buf[offset32.fs_type..][0..value.fs_type32.len], value.fs_type32);
    return buf;
}

/// Where the FAT32 extras sit in the reserved region.
pub const fsinfo_sector: u32 = 1;
pub const backup_sector: u32 = 6;

/// The FSInfo sector. The free count is the whole volume less the cluster the
/// root directory already holds.
pub fn fsInfoSector(clusters: u32) Sector {
    var buf: Sector = .{0} ** sector_bytes;
    put32(&buf, fsinfo_offset.lead, value.fsinfo_lead);
    put32(&buf, fsinfo_offset.structure, value.fsinfo_structure);
    put32(&buf, fsinfo_offset.free_clusters, if (clusters > 0) clusters - 1 else 0);
    put32(&buf, fsinfo_offset.next_free, value.first_free_cluster);
    put32(&buf, fsinfo_offset.trail, value.fsinfo_trail);
    return buf;
}

/// The first sector of a FAT16 table: the two reserved entries and nothing
/// allocated behind them.
pub fn fatHead16() Sector {
    var buf: Sector = .{0} ** sector_bytes;
    put16(&buf, 0, value.fat16_entry0);
    put16(&buf, 2, value.fat16_entry1);
    return buf;
}

/// The first sector of a FAT32 table. Entry 2 ends the chain because the root
/// directory is one cluster long and empty.
pub fn fatHead32() Sector {
    var buf: Sector = .{0} ** sector_bytes;
    put32(&buf, 0, value.fat32_entry0);
    put32(&buf, 4, value.fat32_end_of_chain);
    put32(&buf, 8, value.fat32_end_of_chain);
    return buf;
}
