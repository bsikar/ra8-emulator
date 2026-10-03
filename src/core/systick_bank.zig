//! The Secure and Non-secure SysTick of one core (RA8EMU-154, RA8EMU-397).
//!
//! Both cores carry the Security Extension and two SysTick timers: "Embeds
//! two Systick timers: Secure instance (SysTick_S) and Non-secure instance
//! (SysTick_NS)" (RA8D2/RA8P1 datasheets Rev.1.30 p2; part.cpu0_systicks and
//! part.cpu1_systicks are both 2). Each timer has its own CSR, RVR and CVR,
//! counts on its own, and pends SysTick into its own security state.
//!
//! An access finds its timer by window and by who is asking:
//!
//!   Armv8-M ARM DDI0553A.k
//!     B6.2 RBDNB   SysTick 0xE000_E010..E01F, NS alias 0xE002_E010..E01F
//!     B6.3 RCFPK   the normal window answers in the requester's own state;
//!                  the alias is the Secure view of the Non-secure timer
//!     D1.2         the alias is RES0 to software in Non-secure state
//!
//! The model is pure: the engine adapters own when ticks are charged and
//! where a pend lands.
//!
//! `pends` (RA8EMU-430) says which banked system exceptions are pending and
//! in which state: PendSV always, and SysTick when the part has two timers,
//! pend in their own ICSR (Non-secure copy at 0xE002_ED04, RA8EMU-415) and
//! take their priority from their own SHPR3 (PRI_14 [23:16], PRI_15 [31:24],
//! Non-secure copy at 0xE002_ED20). DDI0553A.k D1.2: ICSR, SHPR3.
const clocks = @import("../periph/clocks.zig");
const scs_alias = @import("../periph/scs_alias.zig");

pub const View = scs_alias.View;

/// The two windows a SysTick register shows up in.
pub const window = struct {
    pub const normal = scs_alias.Span{ .first = 0xE000_E010, .last = 0xE000_E01F };
    pub const alias = scs_alias.Span{ .first = 0xE002_E010, .last = 0xE002_E01F };
};

pub const Register = enum { csr, rvr, cvr, calib };

/// Where an access lands: a timer and the register in it.
pub const Route = struct { view: View, register: Register };

/// One 24-bit SysTick timer.
pub const Timer = struct {
    csr: u32 = 0,
    rvr: u32 = 0,
    cvr: u32 = 0,
    /// Set when a wrap happens with TICKINT on; the caller clears it once it
    /// has pended the exception into this timer's security state.
    pending: bool = false,

    /// Charges `ticks` to a running timer and returns how many times it
    /// wrapped. A disabled timer does not move.
    pub fn advance(self: *Timer, ticks: u32) u64 {
        if (self.csr & clocks.csr_enable == 0) return 0;
        const reload = self.rvr & clocks.counter_mask;
        const moved = clocks.wrap(self.cvr & clocks.counter_mask, reload, ticks);
        self.cvr = moved.value;
        if (moved.periods == 0) return 0;
        self.csr |= clocks.csr_countflag;
        if (self.csr & clocks.csr_tickint != 0) self.pending = true;
        return moved.periods;
    }

    /// A CSR read returns COUNTFLAG and clears it, as on hardware.
    pub fn readCsr(self: *Timer) u32 {
        const value = self.csr;
        self.csr &= ~clocks.csr_countflag;
        return value;
    }
};

/// A core's pair of timers.
pub const Bank = struct {
    secure: Timer = .{},
    non_secure: Timer = .{},

    pub fn of(self: *Bank, view: View) *Timer {
        return switch (view) {
            .secure => &self.secure,
            .non_secure => &self.non_secure,
        };
    }

    /// Both timers see the same core clock.
    pub fn advance(self: *Bank, ticks: u32) void {
        _ = self.secure.advance(ticks);
        _ = self.non_secure.advance(ticks);
    }
};

/// The timer and register an access at `address` from `requester` reaches,
/// or null when it reaches none (outside both windows, or the alias read by
/// Non-secure code, which is RES0).
pub fn route(address: u32, requester: View) ?Route {
    if (window.normal.covers(address)) {
        return .{ .view = requester, .register = registerAt(address - window.normal.first) };
    }
    if (window.alias.covers(address) and requester == .secure) {
        return .{ .view = .non_secure, .register = registerAt(address - window.alias.first) };
    }
    return null;
}

fn registerAt(offset: u32) Register {
    return switch (offset / 4) {
        0 => .csr,
        1 => .rvr,
        2 => .cvr,
        else => .calib,
    };
}

/// The Non-secure timer as a Clocks counts it: its alias registers, pending
/// into the Non-secure ICSR copy at 0xE002_ED04 (RA8EMU-415, RA8EMU-449).
pub const non_secure_words = blk: {
    var words = clocks.Words.non_secure;
    words.icsr = 0xE002_ED04;
    break :blk words;
};

/// The boundary two timers ask for: the shorter armed period, zero when
/// neither is armed (Clocks.period).
pub fn width(secure: u32, non_secure: u32) u32 {
    if (secure == 0) return non_secure;
    if (non_secure == 0) return secure;
    return @min(secure, non_secure);
}

pub const pendsv: u16 = 14;
pub const systick: u16 = 15;

const icsr_pendsvset: u32 = 1 << 28;

/// One pending banked system exception and the state it is taken to.
pub const Pend = struct { number: u16, priority: u8, view: View };

/// The ICSR and SHPR3 words of one Security state's bank.
pub const Words = struct { icsr: u32, shpr3: u32 };

/// Up to four pends, Secure first; `len` says how many are filled.
pub const Pends = struct {
    items: [4]Pend = undefined,
    len: u3 = 0,

    pub fn slice(self: *const Pends) []const Pend {
        return self.items[0..self.len];
    }

    fn add(self: *Pends, pend: Pend) void {
        self.items[self.len] = pend;
        self.len += 1;
    }
};

/// The banked system exceptions pending in `secure` and `non_secure`. With
/// one SysTick timer, SysTick is not banked: only the Secure PENDSTSET and
/// PRI_15 count.
pub fn pends(secure: Words, non_secure: Words, two_timers: bool) Pends {
    var out = Pends{};
    for ([_]View{ .secure, .non_secure }) |view| {
        const words = if (view == .secure) secure else non_secure;
        if (words.icsr & icsr_pendsvset != 0) {
            out.add(.{ .number = pendsv, .priority = @truncate(words.shpr3 >> 16), .view = view });
        }
        if (view == .non_secure and !two_timers) continue;
        if (words.icsr & clocks.icsr_pendstset != 0) {
            out.add(.{ .number = systick, .priority = @truncate(words.shpr3 >> 24), .view = view });
        }
    }
    return out;
}
