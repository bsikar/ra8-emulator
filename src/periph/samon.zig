//! CMSAMON and SFSAMON: the read-only monitors of the code MRAM and SiP flash
//! security split (RA8EMU-420).
//!
//! (R_PSCU at 0x4020_4000, HUM 51.8.11/51.8.12 p3299.) CMSAMON sits at +0x30
//! and SFSAMON at +0x3C. Each carries a nine-bit area in bits 23:15, counted
//! in 32 KB units (Table 51.1), that a boot firmware command wrote to NVM in
//! the OEM state. The application cannot change it, so stores are ignored.
//!
//! A blank part reads 0x1FF. An area the board leaves unprogrammed reads that
//! value too, while the IDAU stays on the bit-28 rule for it (RA8EMU-389):
//! the corpus images were built for boards whose split fits them.
//!
//! Two four-byte windows rather than one span, so the PSCU block keeps its
//! own window and the words between them stay unclaimed.
const periph = @import("registry.zig");

pub const cms_address: u32 = 0x4020_4030;
pub const sfs_address: u32 = 0x4020_403C;

/// The area field's place in the word, and a blank part's area.
pub const area_shift: u5 = 15;
pub const blank: u9 = 0x1FF;

/// The register word a monitor reads for `area`.
pub fn word(area: ?u9) u32 {
    return @as(u32, area orelse blank) << area_shift;
}

pub const Unit = struct {
    /// CMSAMON.CMS: Secure code MRAM in 32 KB units. Null is unprogrammed.
    cms: ?u9 = null,
    /// SFSAMON.SFS: Secure SiP flash in 32 KB units. Null is unprogrammed.
    sfs: ?u9 = null,
    /// Stores the firmware aimed at either monitor; the hardware drops them.
    ignored_stores: u32 = 0,

    pub fn read(self: *const Unit, address: u32, width: u3) u32 {
        _ = width;
        return word(if (address == sfs_address) self.sfs else self.cms);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        _ = .{ address, width, value };
        self.ignored_stores +%= 1;
    }

    pub fn blocks(self: *Unit) [2]periph.Block {
        return .{ self.block("PSCU-CMSAMON", cms_address), self.block("PSCU-SFSAMON", sfs_address) };
    }

    fn block(self: *Unit, name: []const u8, base: u32) periph.Block {
        return .{
            .name = name,
            .base = base,
            .size = 4,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }
};

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Unit = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Unit = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}
