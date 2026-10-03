//! The Zig core's MPU check on an instruction's own data accesses
//! (RA8EMU-369).
//!
//! The core arms the check around one instruction's execution, so the
//! exception entry after it is not checked; the fetch before it is checked
//! on its own through refusesFetch (RA8EMU-368). The board bus asks it about every load and store while it
//! is armed, and a refused access is turned away before it reaches memory:
//! unlike the Unicorn guard (src/core/mpu_guard.zig), the faulting store never
//! lands.
//!
//! The rules are the Unicorn guard's, read from the same table:
//!   - the highest-numbered enabled region covering the address decides,
//!     through Region.refuses (privilege first, then read-only for a store);
//!   - an address no region covers falls to the background
//!     (src/periph/mpu/mpu_background.zig: refused to unprivileged code, and
//!     to privileged code unless PRIVDEFENA);
//!   - a disabled MPU refuses nothing.
//! Two architecture rules the Unicorn guard does not model are kept here
//! (Armv8-M ARM DDI0553A.k B10.1): the PPB, 0xE000_0000..0xE00F_FFFF, is
//! never checked by the MPU, and while the core runs at a negative priority
//! (HardFault, NMI, or FAULTMASK set) the MPU is off unless CTRL.HFNMIENA.
//!
//! A multi-byte access is checked at its first byte.

const mpu = @import("../../periph/mpu/mpu.zig");
const mpu_fault = @import("../../periph/mpu/mpu_fault.zig");
const background = @import("../../periph/mpu/mpu_background.zig");

/// The Private Peripheral Bus, which the MPU never checks.
pub const ppb = struct {
    pub const first: u32 = 0xE000_0000;
    pub const last: u32 = 0xE00F_FFFF;
};

pub const Check = struct {
    unit: *const mpu.Mpu,
    /// True only while an instruction's own accesses are being made.
    armed: bool = false,
    privileged: bool = true,
    /// The first address refused since the check was armed.
    refused: ?u32 = null,

    /// Arm for one instruction. `boosted` is a negative execution priority.
    pub fn arm(self: *Check, privileged: bool, boosted: bool) void {
        self.privileged = privileged;
        self.refused = null;
        self.armed = self.unit.on() and (!boosted or self.unit.ctrl & mpu.field.ctrl_hfnmiena != 0);
    }

    pub fn disarm(self: *Check) void {
        self.armed = false;
    }

    /// Whether one access may go ahead. A refusal is remembered for `take`.
    pub fn allows(self: *Check, address: u32, kind: mpu_fault.Kind) bool {
        if (!self.armed or !refuses(self.unit, address, kind, self.privileged)) return true;
        if (self.refused == null) self.refused = address;
        return false;
    }

    /// Whether the MPU refuses fetching the instruction at `address`
    /// (RA8EMU-368). The fetch is checked on its own, outside the armed
    /// window, with the same negative-priority rule.
    pub fn refusesFetch(self: *const Check, address: u32, privileged: bool, boosted: bool) bool {
        if (boosted and self.unit.ctrl & mpu.field.ctrl_hfnmiena == 0) return false;
        return refuses(self.unit, address, .fetch, privileged);
    }

    /// Check the rest of this instruction's accesses as unprivileged, as
    /// LDRT/STRT ask (RA8EMU-370). Returns the privilege to put back.
    pub fn lower(self: *Check) bool {
        defer self.privileged = false;
        return self.privileged;
    }

    /// The refused address, if any, cleared as it is read.
    pub fn take(self: *Check) ?u32 {
        defer self.refused = null;
        return self.refused;
    }
};

/// Whether the MPU in `unit` refuses one access. The PPB is never refused.
pub fn refuses(unit: *const mpu.Mpu, address: u32, kind: mpu_fault.Kind, privileged: bool) bool {
    if (address >= ppb.first and address <= ppb.last) return false;
    if (!unit.on()) return false;
    if (unit.regionFor(address)) |region| return region.refuses(kind, privileged) != .allowed;
    return background.refuses(unit, privileged);
}
