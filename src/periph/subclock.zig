//! The 32.768 kHz sub-clock crystal oscillator: SOSCCR, which stops and
//! starts it, and SOMCR, which picks the drive strength feeding the crystal.
//!
//! Neither register was in the model before. Both fell through to plain
//! backing store, which got two things wrong at once. SOSCCR came up reading
//! zero, so firmware that asked whether the sub-clock was running before it
//! had started one was told yes; the reset value is 1, stopped
//! (ra8_system_regs.h, "Reset value is 1 (stopped)", HUM Ch 9.2.14 p 339).
//! And SOMCR took a store at any time, which silicon does not allow.
//!
//! THE ORDERING RULE. SOMCR must be written while SOSCCR.SOSTP is 1, that is
//! while the oscillator is stopped (HUM Ch 9.2.29 p 351, recorded in
//! ra8_system_regs.h:160 in those words). ra8_rtc.c's
//! internal_start_count_source writes the pair in exactly that order and says
//! why in its own comment: "set the crystal drive (standard, SOSEL =
//! resonator) while SOSTP is still 1", then SOSTP = 0 to start the crystal,
//! then wait t_SUBOSCWT. A drive change made while the crystal swings does
//! not take on the part, so a model that takes it hands firmware a drive
//! setting the hardware never adopted.
//!
//! BOTH SIT BEHIND PRC0, the same group as the rest of the clock generation
//! circuit: ra8_rtc.c makes both writes inside
//! RA8_PROTECTED_WRITE(k_ra8_prcr_unlock_cgc).
//!
//! WHAT THIS DOES NOT DO. No stabilization time is modelled, and the
//! sub-clock raises no OSCSF flag, because it has none: OSCSF carries HOCO,
//! the main oscillator and the two PLLs, and the sub-clock is not among them.
//! Starting it here is immediate, so t_SUBOSCWT is a wait firmware takes and
//! the model does not enforce. No rate is derived either; nothing downstream
//! counts on 32.768 kHz yet.
const periph = @import("registry.zig");
const prcr = @import("prcr.zig");
const lanes = @import("lanes.zig");

/// Window geometry: SYSC base 0x4001_E000, SOSCCR (+0xC00) and SOMCR (+0xC01).
pub const win_base: u32 = 0x4001_EC00;
pub const win_span: u32 = 2;

/// Register offsets from `win_base`.
pub const regs = struct {
    pub const sosccr: u32 = 0x00;
    pub const somcr: u32 = 0x01;
};

pub const field = struct {
    /// SOSCCR.SOSTP: 0 operates the crystal, 1 stops it.
    pub const sostp: u8 = 1 << 0;
    /// SOMCR.SODRV[1:0]: the drive-capability code.
    pub const sodrv: u8 = 0x03;
};

/// The four SODRV codes, from ra8_somcr_drv_t. Standard is the cold-reset
/// default and the one the EK-RA8D2 watch crystal wants.
pub const Drive = enum(u2) {
    standard,
    lp1,
    lp2,
    lp3,

    pub fn name(self: Drive) []const u8 {
        return switch (self) {
            .standard => "standard (12.5 pF)",
            .lp1 => "low power 1 (9 pF)",
            .lp2 => "low power 2 (7 pF)",
            .lp3 => "low power 3 (4 pF)",
        };
    }
};

/// The PRCR group both registers sit behind: PRC0, the clock generation
/// circuit.
pub const guard: u16 = prcr.group.cgc;

/// The two words, and what the run did to them.
pub const Unit = struct {
    /// The board's live protection model, not a copy of it.
    protection: *const prcr.Prcr,
    /// Reset value is SOSTP set: the crystal comes up stopped.
    sosccr: u8 = field.sostp,
    somcr: u8 = 0,
    /// Stores that landed, either register.
    stores: u32 = 0,
    /// Stores dropped because PRCR.PRC0 was locked.
    dropped_locked: u32 = 0,
    /// SOMCR stores refused because the crystal was already swinging.
    refused_running: u32 = 0,
    /// Times firmware cleared SOSTP and started the crystal.
    starts: u32 = 0,

    pub fn init(protection: *const prcr.Prcr) Unit {
        return .{ .protection = protection };
    }

    pub fn quiet(self: *const Unit) bool {
        return self.stores == 0 and self.dropped_locked == 0 and
            self.refused_running == 0;
    }

    /// Whether the crystal is swinging right now.
    pub fn running(self: *const Unit) bool {
        return self.sosccr & field.sostp == 0;
    }

    pub fn drive(self: *const Unit) Drive {
        return @enumFromInt(@as(u2, @truncate(self.somcr & field.sodrv)));
    }

    pub fn read(self: *const Unit, address: u32, width: u3) u32 {
        const word: u32 = (@as(u32, self.somcr) << 8) | self.sosccr;
        return lanes.part(word, address - win_base, width);
    }

    pub fn write(self: *Unit, address: u32, width: u3, value: u32) void {
        if (!self.protection.unlocked(guard)) {
            self.dropped_locked +%= 1;
            return;
        }
        const lane = address - win_base;
        // Two separate 8-bit registers, so each byte of the access is judged
        // on its own against the state standing BEFORE any of it lands.
        const was_running = self.running();
        var landed = false;
        if (lane + width > regs.somcr) {
            const shift: u5 = if (lane == regs.sosccr) 8 else 0;
            landed = self.storeMode(@truncate(value >> shift), was_running);
        }
        if (lane == regs.sosccr) {
            self.storeControl(@truncate(value), was_running);
            landed = true;
        }
        if (landed) self.stores +%= 1;
    }

    /// SOMCR takes the drive code only while the crystal is stopped. Returns
    /// whether the byte landed.
    fn storeMode(self: *Unit, value: u8, was_running: bool) bool {
        if (was_running) {
            self.refused_running +%= 1;
            return false;
        }
        self.somcr = value;
        return true;
    }

    fn storeControl(self: *Unit, value: u8, was_running: bool) void {
        self.sosccr = value;
        if (!was_running and self.running()) self.starts +%= 1;
    }

    pub fn block(self: *Unit) periph.Block {
        return .{
            .name = "SOSC",
            .base = win_base,
            .size = win_span,
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
