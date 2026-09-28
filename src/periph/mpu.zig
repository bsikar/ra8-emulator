//! MPU_TYPE: how many data regions the core says it has, and why a zero there
//! parks an image in `main`.
//!
//! The PPB is plain RAM in this model, so every MPU register a firmware writes
//! lands and reads back for free. TYPE is the one that does not work that way:
//! it is read-only and hardwired, and nothing writes it, so it read as zero.
//! `ra8_mpu_configure` opens by validating capacity, `if (cfg.region_count >
//! dregionCount()) return .invalid_arg`, and every RA8 image that programs the
//! MPU asks for at least one region. So the call was rejected before it touched
//! a single register, and `main` spun forever on the `wfi` beside its call site:
//!
//!     bl      ra8_mpu_configure
//!     cmp     r3, #0
//!     beq.n   main+0x22        ; the rest of main, never taken
//!     wfi                      ; ... and the branch back to it
//!
//! threadx_mpu_partition_demo never reached `_tx_initialize_kernel_enter` for
//! this reason: no SysTick armed, no interrupt taken, nothing to show for a
//! whole budget. dev's C emulator seeds the same word for the same reason, and
//! says so at `k_mpu_type_seed` in emu_exc.h: 8 data regions, matching the
//! Cortex-M85 the RA8D2 carries. That count is taken from there, not guessed.
//!
//!   MPU_TYPE 0xE000_ED90 (DDI0553 D1.2.16)
//!     DREGION [15:8] read-only, hardwired: the number of data regions
//!     SEPARATE [0]   read-only, zero: one unified region set
//!
//! TWO THINGS THIS BLOCK DOES NOT DO, both measured with
//! fw/probe/mpuregions.c rather than assumed, and both left for later slices.
//!
//! RBAR/RLAR ARE NOT BANKED THROUGH RNR. On silicon RNR selects which of the
//! eight region pairs the one RBAR/RLAR address reaches, so programming region
//! 3 and then pointing RNR back at region 0 reads region 0's base again. Here
//! the PPB is plain RAM and RBAR is one word, so that readback gives region 3's
//! base. The probe stops at step 5 on this and it is the next slice in this
//! vein: it needs the window served as a bus block rather than observed over
//! RAM, which is why it is not folded in here. It costs nothing yet because no
//! RA8 image in the corpus reads a region back after programming it; they
//! write the table and enable it.
//!
//! NOTHING HERE ENFORCES A REGION. A privileged store into a read-only region
//! is a MemManage violation on silicon, and Unicorn's core models no MPU, so
//! dev synthesises the exception from a write hook over each read-only range
//! (emu_mpu.c). The table is captured so that enforcement has something to read
//! and so the report can say what the firmware programmed; the fault itself is
//! not modelled and an image that relies on one still runs on.
const memmap = @import("../core/memmap.zig");

/// The register block's fixed shape: how many data regions this core reports,
/// and where DREGION sits in TYPE.
pub const geometry = struct {
    /// Data regions the modelled core implements. dev's emu_exc.h seeds
    /// MPU_TYPE with 0x0000_0800 and calls it "8 data regions (matches the
    /// M85 MPU)"; emu_mpu.c carries the same 8 as its table length.
    pub const regions: u8 = 8;
    pub const dregion_shift: u5 = 8;
    /// What a read of TYPE gives back. SEPARATE reads zero: the Armv8-M MPU
    /// has one unified region set, not split instruction and data sets.
    pub const type_value: u32 = @as(u32, regions) << dregion_shift;

    /// The region a select value names, wrapped into the implemented set the
    /// way a 3-bit RNR field does with 8 regions.
    pub fn selects(rnr: u32) u8 {
        return @intCast(rnr % regions);
    }
};

pub const field = struct {
    /// CTRL[0] ENABLE, [1] HFNMIENA, [2] PRIVDEFENA.
    pub const ctrl_enable: u32 = 1 << 0;
    pub const ctrl_hfnmiena: u32 = 1 << 1;
    pub const ctrl_privdefena: u32 = 1 << 2;
    /// RBAR[0] XN, [2:1] AP. AP[2] set is read-only at both privilege levels.
    pub const rbar_xn: u32 = 1 << 0;
    pub const rbar_ap_ro: u32 = 1 << 2;
    /// RLAR[0] EN, the region-enable bit.
    pub const rlar_enable: u32 = 1 << 0;
    /// BASE and LIMIT hold [31:5]: regions are aligned and sized in 32 bytes.
    pub const address: u32 = 0xFFFF_FFE0;
    /// A LIMIT is inclusive, so the low five bits the field cannot hold read
    /// as ones rather than zeros.
    pub const limit_low: u32 = 0x1F;
};

/// One data region as the firmware left it: the inclusive span it covers, and
/// the two bits that decide whether a store into it is allowed.
pub const Region = struct {
    base: u32 = 0,
    limit: u32 = 0,
    read_only: bool = false,
    executable: bool = true,
    enabled: bool = false,

    /// Read one region out of the RBAR/RLAR pair that programs it.
    pub fn fromPair(rbar: u32, rlar: u32) Region {
        return .{
            .base = rbar & field.address,
            .limit = (rlar & field.address) | field.limit_low,
            .read_only = rbar & field.rbar_ap_ro != 0,
            .executable = rbar & field.rbar_xn == 0,
            .enabled = rlar & field.rlar_enable != 0,
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

/// The MPU window: the hardwired count the firmware reads out of it, and the
/// region table it programmes into it.
pub const Mpu = struct {
    table: [geometry.regions]Region = [_]Region{.{}} ** geometry.regions,
    /// RNR as the firmware last left it.
    selected: u8 = 0,
    /// CTRL as the firmware last left it, so the report can say which of the
    /// three configuration bits it asked for.
    ctrl: u32 = 0,
    /// Transitions of CTRL.ENABLE, so a run that turns the MPU on and off
    /// around a reprogramme is distinguishable from one that never used it.
    enables: u32 = 0,
    disables: u32 = 0,
    /// Stores to TYPE turned away, the read-only rule this block enforces.
    refused: u32 = 0,

    pub fn init() Mpu {
        return .{};
    }

    /// Put the hardwired count in place, so the firmware's first read of TYPE
    /// is this core's region count rather than the zero the mapping starts at.
    pub fn prime(self: *Mpu, core: anytype) !void {
        _ = self;
        try core.writeWord(memmap.mpu.type_, geometry.type_value);
    }

    /// Read the window: keep TYPE read-only, then capture the table the
    /// firmware has programmed and which way CTRL.ENABLE has moved.
    pub fn poll(self: *Mpu, core: anytype) !void {
        if (try core.readWord(memmap.mpu.type_) != geometry.type_value) {
            self.refused +%= 1;
            try core.writeWord(memmap.mpu.type_, geometry.type_value);
        }
        try self.readTable(core);
        const ctrl = try core.readWord(memmap.mpu.ctrl);
        const was_on = self.ctrl & field.ctrl_enable != 0;
        const is_on = ctrl & field.ctrl_enable != 0;
        if (is_on and !was_on) self.enables +%= 1;
        if (was_on and !is_on) self.disables +%= 1;
        self.ctrl = ctrl;
    }

    /// RNR names one region; the three alias pairs reach the three that follow
    /// it without another RNR write, which is how a driver programmes four
    /// regions in one go. Each pair is read where it lands. This sees the
    /// table as it stands AT THE POLL, not every state it passed through: a
    /// driver that walks RNR and rewrites the one unaliased pair faster than
    /// the poll seam leaves only its last pair visible. Enough for the report
    /// and for what the corpus does; see the banking note in the file header.
    fn readTable(self: *Mpu, core: anytype) !void {
        self.selected = geometry.selects(try core.readWord(memmap.mpu.rnr));
        const pairs = [_][2]u32{
            .{ memmap.mpu.rbar, memmap.mpu.rlar },
            .{ memmap.mpu.rbar_a1, memmap.mpu.rlar_a1 },
            .{ memmap.mpu.rbar_a2, memmap.mpu.rlar_a2 },
            .{ memmap.mpu.rbar_a3, memmap.mpu.rlar_a3 },
        };
        for (pairs, 0..) |pair, offset| {
            const which = geometry.selects(self.selected + @as(u32, @intCast(offset)));
            self.table[which] = Region.fromPair(
                try core.readWord(pair[0]),
                try core.readWord(pair[1]),
            );
        }
    }

    pub fn on(self: *const Mpu) bool {
        return self.ctrl & field.ctrl_enable != 0;
    }

    pub fn privilegedDefault(self: *const Mpu) bool {
        return self.ctrl & field.ctrl_privdefena != 0;
    }

    /// How many regions the firmware left enabled.
    pub fn programmed(self: *const Mpu) u8 {
        var count: u8 = 0;
        for (self.table) |region| {
            if (region.enabled) count += 1;
        }
        return count;
    }

    /// How many of those are read-only, the ones enforcement will care about.
    pub fn readOnly(self: *const Mpu) u8 {
        var count: u8 = 0;
        for (self.table) |region| {
            if (region.enabled and region.read_only) count += 1;
        }
        return count;
    }

    /// The enabled region covering an address, highest-numbered first the way
    /// the architecture resolves an overlap, or null when none does.
    pub fn regionFor(self: *const Mpu, at: u32) ?Region {
        var i: usize = self.table.len;
        while (i > 0) {
            i -= 1;
            if (self.table[i].covers(at)) return self.table[i];
        }
        return null;
    }
};
