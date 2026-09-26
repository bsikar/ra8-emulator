//! Formatting a blank card: solve the volume geometry for the card's own
//! size, then lay the metadata region out on it.
//!
//! dev builds a FAT volume in a fresh sparse host file behind `--sd-new`
//! (board_periph_sd_format.c). The card in this tree is the RAM-backed image
//! next door, so the same work lands in blocks instead of a file descriptor,
//! and the geometry solvers keep dev's shape. Five things that model does not
//! do:
//!
//! THE CLUSTER COUNT DECIDES THE TYPE. dev formats whatever it is asked for.
//! Its FAT16 solver doubles the cluster size until the count fits, and when
//! it runs out of cluster sizes it gives up and writes the BPB anyway, so a
//! large card comes back stamped "FAT16   " over more clusters than a 16-bit
//! FAT can address; the same routine writes "FAT32   " over a volume with far
//! too few. Either one is a card whose own cluster count contradicts the type
//! it declares, which is how a driver picks the wrong FAT width and walks off
//! the end of the table. Here the counts the specification fixes are checked
//! and a volume outside them is refused.
//!
//! A CARD TOO SMALL IS NOT FORMATTED. dev subtracts the reserved and root
//! regions from the sector count in unsigned arithmetic with no floor under
//! it, so a card smaller than its own metadata wraps and produces a BPB for a
//! volume that does not exist. Refused here.
//!
//! A FORMAT CLEARS WHAT WAS THERE. dev writes the boot sector and the head of
//! each FAT copy and nothing else. On a fresh sparse file that is enough; on
//! a card that already holds something it is not, and the rest of the FAT,
//! the root directory and the reserved region all survive the format, so the
//! volume mounts showing entries from the card before it. Here the whole
//! metadata region is given back first.
//!
//! A LABEL THAT DOES NOT FIT IS NOT A LABEL. dev pads at eleven bytes and
//! truncates anything longer in silence, and copies any byte at all into the
//! field, control characters included. Refused here; see sd_fat.zig.
//!
//! THE BACKUP IS A WHOLE BACKUP. dev copies the boot sector to the backup at
//! sector 6 and leaves the FSInfo that belongs with it unwritten, so a repair
//! falling back to the backup finds half a pair. Both are written here.
const std = @import("std");
const image = @import("sd_image.zig");
const fat = @import("sd_fat.zig");

/// The FAT widths this model formats. FAT12 is not one of them: nothing in
/// this tree reads a card small enough to need it.
pub const Kind = enum {
    fat16,
    fat32,

    /// The name as it arrives on the command line, or null. An unknown name
    /// is the caller's to refuse; nothing here picks a default.
    pub fn parse(name: []const u8) ?Kind {
        if (std.ascii.eqlIgnoreCase(name, "fat16")) return .fat16;
        if (std.ascii.eqlIgnoreCase(name, "fat32")) return .fat32;
        return null;
    }

    pub fn text(self: Kind) []const u8 {
        return switch (self) {
            .fat16 => "FAT16",
            .fat32 => "FAT32",
        };
    }
};

/// The numbers the format itself fixes, plus the two this model chooses.
pub const rule = struct {
    /// Two FAT copies, the count every consumer card ships with.
    pub const fats: u32 = 2;
    pub const root_entries: u32 = 512;
    pub const dir_entry_bytes: u32 = 32;
    pub const reserved_fat16: u32 = 1;
    pub const reserved_fat32: u32 = 32;
    pub const max_sectors_per_cluster: u32 = 64;
    /// The cluster counts that make a volume one width rather than another.
    pub const fat16_min_clusters: u32 = 4085;
    pub const fat16_max_clusters: u32 = 65524;
    pub const fat32_min_clusters: u32 = 65525;
    pub const fat32_max_clusters: u32 = 0x0FFF_FFF5;
    /// Above this the cluster size is doubled so the table stays bounded:
    /// 512K clusters is 2 MiB of FAT per copy. This model's own choice.
    pub const fat32_preferred_clusters: u32 = 512 * 1024;
};

pub const Error = error{
    CardTooSmall,
    TooFewClusters,
    TooManyClusters,
    BadLabel,
    WriteRefused,
};

/// What a format produced, for the end-of-run report.
pub const Volume = struct {
    kind: Kind,
    layout: fat.Layout,
    /// Blocks the card was holding in the metadata region, given back.
    cleared: u32,
};

/// Solve the geometry for a card of `total_sectors`, or say why this width
/// cannot describe it.
pub fn solve(kind: Kind, total_sectors: u32) Error!fat.Layout {
    return switch (kind) {
        .fat16 => solveFat16(total_sectors),
        .fat32 => solveFat32(total_sectors),
    };
}

/// Format the card the image holds and return what landed on it.
pub fn apply(img: *image.Image, kind: Kind, label: []const u8) Error!Volume {
    const layout = try solve(kind, img.capacity_blocks);
    const metadata = layout.reserved_sectors + rule.fats * layout.fat_sectors + layout.root_sectors;
    const cleared = img.zero(0, metadata - 1);
    switch (kind) {
        .fat16 => try writeFat16(img, layout, label),
        .fat32 => try writeFat32(img, layout, label),
    }
    return .{ .kind = kind, .layout = layout, .cleared = cleared };
}

/// A FAT16 volume: the boot sector, then the head of each FAT copy.
fn writeFat16(img: *image.Image, layout: fat.Layout, label: []const u8) Error!void {
    const boot = try fat.bootSector16(layout, rule.fats, label);
    try put(img, 0, &boot);
    try fatHeads(img, layout, fat.fatHead16());
}

/// A FAT32 volume: the boot sector, the FSInfo beside it, both again in the
/// backup pair, then the head of each FAT copy.
fn writeFat32(img: *image.Image, layout: fat.Layout, label: []const u8) Error!void {
    const boot = try fat.bootSector32(layout, rule.fats, label);
    const info = fat.fsInfoSector(layout.clusters);
    try put(img, 0, &boot);
    try put(img, fat.fsinfo_sector, &info);
    try put(img, fat.backup_sector, &boot);
    try put(img, fat.backup_sector + fat.fsinfo_sector, &info);
    try fatHeads(img, layout, fat.fatHead32());
}

fn fatHeads(img: *image.Image, layout: fat.Layout, head: fat.Sector) Error!void {
    var copy: u32 = 0;
    while (copy < rule.fats) : (copy += 1) {
        try put(img, layout.reserved_sectors + copy * layout.fat_sectors, &head);
    }
}

fn put(img: *image.Image, index: u32, block: *const image.Block) Error!void {
    if (!img.write(index, block)) return error.WriteRefused;
}

/// The sectors the fixed FAT16 root directory occupies.
fn rootSectors() u32 {
    const bytes: u32 = @intCast(fat.sector_bytes);
    return (rule.root_entries * rule.dir_entry_bytes + bytes - 1) / bytes;
}

/// FAT16 geometry: grow the cluster until the count fits under the 16-bit
/// ceiling, recomputing the table length each round because each depends on
/// the other. dev's loop, with the two ends of the range enforced.
fn solveFat16(total_sectors: u32) Error!fat.Layout {
    const root = rootSectors();
    const overhead = rule.reserved_fat16 + root;
    var spc: u32 = 1;
    while (true) {
        if (total_sectors <= overhead + rule.fats) return error.CardTooSmall;
        const usable = total_sectors - overhead;
        // 256 entries of two bytes fit a sector, one per cluster.
        const per_sector = 256 * spc + rule.fats;
        const fat_sectors = (usable + per_sector - 1) / per_sector;
        if (usable <= rule.fats * fat_sectors) return error.CardTooSmall;
        const clusters = (usable - rule.fats * fat_sectors) / spc;
        if (clusters <= rule.fat16_max_clusters) {
            if (clusters < rule.fat16_min_clusters) return error.TooFewClusters;
            return .{
                .total_sectors = total_sectors,
                .sectors_per_cluster = spc,
                .reserved_sectors = rule.reserved_fat16,
                .fat_sectors = fat_sectors,
                .root_sectors = root,
                .clusters = clusters,
            };
        }
        if (spc >= rule.max_sectors_per_cluster) return error.TooManyClusters;
        spc *= 2;
    }
}

/// FAT32 geometry: the same shape, grown until the table is bounded rather
/// than until the count fits, since a 32-bit FAT has room to spare.
fn solveFat32(total_sectors: u32) Error!fat.Layout {
    var spc: u32 = 1;
    while (true) {
        if (total_sectors <= rule.reserved_fat32 + rule.fats) return error.CardTooSmall;
        const usable = total_sectors - rule.reserved_fat32;
        // 128 entries of four bytes fit a sector; the divisor is Microsoft's.
        const per_sector = 128 * spc + 1;
        const fat_sectors = (usable + per_sector - 1) / per_sector;
        if (usable <= rule.fats * fat_sectors) return error.CardTooSmall;
        const clusters = (usable - rule.fats * fat_sectors) / spc;
        const bounded = clusters <= rule.fat32_preferred_clusters;
        if (bounded or spc >= rule.max_sectors_per_cluster) {
            if (clusters < rule.fat32_min_clusters) return error.TooFewClusters;
            if (clusters > rule.fat32_max_clusters) return error.TooManyClusters;
            return .{
                .total_sectors = total_sectors,
                .sectors_per_cluster = spc,
                .reserved_sectors = rule.reserved_fat32,
                .fat_sectors = fat_sectors,
                .root_sectors = 0,
                .clusters = clusters,
            };
        }
        spc *= 2;
    }
}
