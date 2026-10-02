//! The Non-secure alias of the System Control Space, and which bank of the
//! SCS registers an access lands on.
//!
//! A part with the Security Extension shows the SCS twice. The normal window
//! answers in the state of whoever is asking: Secure code sees the Secure
//! bank, Non-secure code the Non-secure one. The alias window, 0x0002_0000
//! higher, is how Secure code reaches the Non-secure bank of the same
//! register (the TrustZone set-up code programs VTOR_NS through it, for
//! example).
//!
//!   Armv8-M ARM DDI0553A.k
//!     B6.2 RBDNB   SCS 0xE000_E000..0xE000_EFFF, NS alias 0xE002_E000..EFFF,
//!                  SCB 0xE000_ED00..ED8F and its alias 0xE002_ED00..ED8F
//!     B6.3 RCFPK   the Secure view of the NS alias is the Non-secure view
//!                  of the normal address, unless a register says otherwise
//!
//! What a Non-secure access to the alias window does is not pinned here. The
//! answer says so (`alias_from_non_secure`) and leaves the call to whoever
//! owns the bus, rather than this file guessing at a rule it has not read.

/// Which bank of a banked SCS register an access reads or writes.
pub const View = enum { secure, non_secure };

/// A closed address range.
pub const Span = struct {
    first: u32,
    last: u32,

    pub fn covers(self: Span, address: u32) bool {
        return address >= self.first and address <= self.last;
    }
};

/// The normal SCS window and the System Control Block inside it.
pub const scs = Span{ .first = 0xE000_E000, .last = 0xE000_EFFF };
pub const scb = Span{ .first = 0xE000_ED00, .last = 0xE000_ED8F };

/// How far the alias sits above the normal window.
pub const offset: u32 = 0x0002_0000;

/// The alias windows, derived so they can never drift from the normal ones.
pub const scs_ns = Span{ .first = scs.first + offset, .last = scs.last + offset };
pub const scb_ns = Span{ .first = scb.first + offset, .last = scb.last + offset };

/// Where an access goes: the register's address in the normal window, and
/// the bank it uses.
pub const Target = struct {
    address: u32,
    view: View,
};

pub const Route = union(enum) {
    /// Not an SCS address at all.
    outside,
    /// An SCS register, in the bank given.
    register: Target,
    /// Non-secure code touching the alias window; see the file comment.
    alias_from_non_secure: u32,
};

/// Route one access from code running in the state `secure` says.
pub fn route(address: u32, secure: bool) Route {
    if (scs.covers(address)) {
        return .{ .register = .{
            .address = address,
            .view = if (secure) .secure else .non_secure,
        } };
    }
    if (scs_ns.covers(address)) {
        if (!secure) return .{ .alias_from_non_secure = address - offset };
        return .{ .register = .{ .address = address - offset, .view = .non_secure } };
    }
    return .outside;
}

/// True when `address` is an SCB register through either window.
pub fn isScb(address: u32) bool {
    return scb.covers(address) or scb_ns.covers(address);
}
