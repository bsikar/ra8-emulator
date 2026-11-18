//! The Armv8-M Security Attribution Unit register window.
//!
//! This block exists because of ONE READ. The secure boot's SAU bring-up
//! opens with `SAU_TYPE & 0xFF` and programmes nothing at all unless the
//! count it finds there is bigger than the number of regions its boot map
//! needs. The PPB is mapped as ordinary RAM, so that read gave back zero,
//! the check failed, and ra8_tz_secure_boot_sau_init returned 0x107 without
//! writing a single region. Everything downstream of it in the secure boot
//! (the security init, the CPU1 release, the BLXNS into the Non-Secure
//! image) hangs off that return, so a run of cpu1_pingpong_ipc parked in the
//! Secure fallback main() forever and reported nothing about TrustZone at
//! all. TYPE is hardwired on silicon; nothing the firmware does would ever
//! have put the count there, so the model has to.
//!
//! RBAR/RLAR ARE BANKED THROUGH RNR, the same shape src/chip/periph/mpu/mpu.zig
//! already carries for the MPU window beside this one. Five regions get
//! programmed as five RNR/RBAR/RLAR triples, and with the PPB as plain RAM
//! each triple would overwrite the last and the table would read back
//! holding only the fifth. The block keeps its own table, filed under the
//! region RNR names at the moment of the store.
//!
//! ATTRIBUTION IS NOT ENFORCED HERE and that is deliberate, said plainly so
//! a later slice does not mistake the gap for an oversight. This model runs
//! one flat, fully-accessible address space; it has no Secure and
//! Non-Secure worlds to place an access in. What the block does is answer
//! the capability read honestly and keep the map the firmware programmed, so
//! the report can say what the firmware asked for. Refusing accesses by it
//! is a separate piece of work and needs the world split first.
const memmap = @import("../../core/memmap.zig");

/// What the programmed map says about an address. src/chip/periph/sau/attribution.zig.
pub const attribution = @import("attribution.zig");

/// The RA8 IDAU map that feeds the attribution. src/chip/periph/idau.zig.
pub const idau = @import("../idau.zig");

/// The window's fixed shape: how many regions this core reports out of TYPE.
pub const geometry = struct {
    /// Regions the modelled core implements by default.
    pub const regions: u8 = 8;
    /// Maximum configurable SAU regions supported by the table.
    pub const max_regions: usize = 16;
    /// What a read of TYPE gives back: SREGION sits in the low byte and the
    /// rest of the word is reserved.
    pub const type_value: u32 = regions;

    /// TYPE word for an arbitrary configured SAU region count.
    pub fn typeValueFor(count: u8) u32 {
        return @min(count, @as(u8, max_regions));
    }

    /// The region a select value names, wrapped into the default 8-region set.
    pub fn selects(rnr: u32) u8 {
        return selectsIn(rnr, regions);
    }

    /// The region a select value names, wrapped into `count` regions.
    pub fn selectsIn(rnr: u32, count: u8) u8 {
        const active = @min(count, @as(u8, max_regions));
        if (active == 0) return 0;
        return @intCast(rnr % active);
    }
};

pub const field = struct {
    /// CTRL[0] ENABLE, [1] ALLNS: whether memory outside every region is
    /// treated as Non-Secure.
    pub const ctrl_enable: u32 = 1 << 0;
    pub const ctrl_allns: u32 = 1 << 1;
    /// TYPE.SREGION, the implemented region count.
    pub const sregion: u32 = 0x0000_00FF;
    /// RLAR[0] ENABLE, [1] NSC: the region is Non-Secure Callable rather
    /// than plain Non-Secure.
    pub const rlar_enable: u32 = 1 << 0;
    pub const rlar_nsc: u32 = 1 << 1;
    /// BADDR and LADDR hold [31:5]: regions are aligned and sized in 32
    /// bytes, as in the MPU window.
    pub const address: u32 = 0xFFFF_FFE0;
    /// A LIMIT is inclusive, so the low five bits the field cannot hold read
    /// as ones rather than zeros.
    pub const limit_low: u32 = 0x1F;
};

/// One region as the firmware left it: the inclusive span it covers and what
/// it says about that span's security attribution.
pub const Region = struct {
    base: u32 = 0,
    limit: u32 = 0,
    /// RLAR.NSC. A Non-Secure Callable region is the narrow door Secure code
    /// leaves open for Non-Secure callers, so it is worth telling apart from
    /// a plainly Non-Secure one in the report.
    callable: bool = false,
    enabled: bool = false,
    /// The two words exactly as the firmware wrote them, kept whole so
    /// putting a region back in front of the firmware after an RNR change
    /// returns what it programmed, reserved bits and all.
    rbar: u32 = 0,
    rlar: u32 = 0,

    /// Read one region out of the RBAR/RLAR pair that programs it.
    pub fn fromPair(rbar: u32, rlar: u32) Region {
        return .{
            .base = rbar & field.address,
            .limit = (rlar & field.address) | field.limit_low,
            .callable = rlar & field.rlar_nsc != 0,
            .enabled = rlar & field.rlar_enable != 0,
            .rbar = rbar,
            .rlar = rlar,
        };
    }

    /// Whether an address falls inside this region, span only: an entry that
    /// is not enabled covers nothing.
    pub fn covers(self: Region, at: u32) bool {
        return self.enabled and at >= self.base and at <= self.limit;
    }

    pub fn bytes(self: Region) u32 {
        if (!self.enabled or self.limit < self.base) return 0;
        return self.limit - self.base + 1;
    }
};

/// The SAU window: the hardwired count the firmware reads out of it, and the
/// region map it programmes into it.
pub const Sau = struct {
    table: [geometry.max_regions]Region = @splat(.{}),
    /// Implemented SAU region count advertised in SAU_TYPE.SREGION (0..max_regions).
    region_count: u8 = geometry.regions,
    /// RNR as the firmware last left it.
    selected: u8 = 0,
    /// CTRL as the firmware last left it, so the report can say whether the
    /// firmware finished by switching attribution on.
    ctrl: u32 = 0,
    /// Stores to TYPE turned away, the read-only rule this block enforces.
    refused: u32 = 0,
    /// Stores into a banked RBAR or RLAR, so a run that programmed the map
    /// is distinguishable from one that read TYPE and gave up.
    banked: u32 = 0,

    pub fn init() Sau {
        return .{};
    }

    pub fn setRegions(self: *Sau, count: u8) void {
        self.region_count = @min(count, @as(u8, geometry.max_regions));
        self.selected = geometry.selectsIn(self.selected, self.region_count);
        if (self.region_count == 0) self.ctrl = 0;
    }

    pub fn typeValue(self: *const Sau) u32 {
        return geometry.typeValueFor(self.region_count);
    }

    /// Put the hardwired count in place, so the firmware's first read of
    /// TYPE is this core's region count rather than the zero the mapping
    /// starts at.
    pub fn prime(self: *Sau, core: anytype) !void {
        try core.writeWord(memmap.sau.type_, self.typeValue());
    }

    /// Keep TYPE read-only. A store that lands on it is counted and the
    /// count put back, the same rule the MPU window keeps over its own TYPE.
    pub fn poll(self: *Sau, core: anytype) !void {
        const expected = self.typeValue();
        if (try core.readWord(memmap.sau.type_) != expected) {
            self.refused +%= 1;
            try core.writeWord(memmap.sau.type_, expected);
        }
    }

    /// Whether a store into the window asks for the banked pair to be put
    /// back in front of the firmware.
    pub const Cue = enum { none, rebank };

    /// File one store into the window under the region RNR names, and say
    /// whether the selection moved.
    pub fn observe(self: *Sau, address: u32, value: u32) Cue {
        if (self.region_count == 0) {
            if (address == memmap.sau.ctrl) self.ctrl = value & field.ctrl_allns;
            return .none;
        }
        switch (address) {
            memmap.sau.rnr => {
                self.selected = geometry.selectsIn(value, self.region_count);
                return .rebank;
            },
            memmap.sau.ctrl => self.ctrl = value,
            memmap.sau.rbar => {
                const slot = &self.table[self.selected];
                slot.* = Region.fromPair(value, slot.rlar);
                self.banked +%= 1;
            },
            memmap.sau.rlar => {
                const slot = &self.table[self.selected];
                slot.* = Region.fromPair(slot.rbar, value);
                self.banked +%= 1;
            },
            else => {},
        }
        return .none;
    }

    /// The pair the firmware should read back for the selected region.
    pub fn bankedPair(self: *const Sau) Region {
        if (self.region_count == 0) return .{};
        return self.table[self.selected];
    }

    pub fn on(self: *const Sau) bool {
        return self.region_count > 0 and self.ctrl & field.ctrl_enable != 0;
    }

    /// Whether memory outside every enabled SAU region is treated as
    /// Non-secure. With zero SAU regions configured, the SAU contributes
    /// Non-secure so attribution defers purely to the IDAU.
    pub fn outsideIsNonSecure(self: *const Sau) bool {
        if (self.region_count == 0) return true;
        return self.ctrl & field.ctrl_allns != 0;
    }

    pub fn programmed(self: *const Sau) u8 {
        var count: u8 = 0;
        for (self.table[0..@min(self.region_count, @as(u8, geometry.max_regions))]) |region| {
            if (region.enabled) count += 1;
        }
        return count;
    }

    pub fn callable(self: *const Sau) u8 {
        var count: u8 = 0;
        for (self.table[0..@min(self.region_count, @as(u8, geometry.max_regions))]) |region| {
            if (region.enabled and region.callable) count += 1;
        }
        return count;
    }

    pub fn quiet(self: *const Sau) bool {
        return !self.on() and self.programmed() == 0 and self.refused == 0;
    }
};
