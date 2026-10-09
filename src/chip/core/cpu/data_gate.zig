//! SAU/IDAU attribution on the Zig core's data accesses (RA8EMU-274).
//!
//! A load or store made while the core is Non-secure may only reach
//! Non-secure memory or an exempt range. Anything the attribution source
//! calls Secure or Non-secure-callable is refused before it lands, and
//! Cpu.step takes the SecureFault (SFSR.AUVIOL, SFAR = the refused address).
//!
//! The gate sits on the Bus (src/chip/core/cpu/bus.zig) so one check covers every
//! load, store and exclusive an instruction makes. It is armed only while an
//! instruction executes: the fetch has its own check (INVEP, RA8EMU-359 and
//! RA8EMU-273), and exception entry, vector reads and stacking run in the
//! state they target, which RA8EMU-168 still has to switch.
const attribution = @import("attribution.zig");
const banked = @import("../banked.zig");

pub const Gate = struct {
    source: attribution.Attribution,
    /// The core's running security state (Cpu.banked.current).
    current: *const banked.State,
    /// True while an instruction executes.
    armed: bool = false,
    /// The address of the access last refused, which SFAR reports: the
    /// access's own address even when only its far end is Secure.
    refused: u32 = 0,

    /// Whether an access of `len` bytes at `address` is refused now.
    pub inline fn refuses(self: *Gate, address: u32, len: usize) bool {
        if (!self.armed or self.current.* == .secure or len == 0) return false;
        return self.outside(address, len);
    }

    /// Both ends of the access are checked: regions are 32-byte granular, so
    /// an access of up to 64 bytes crosses at most one boundary.
    fn outside(self: *Gate, address: u32, len: usize) bool {
        const last = address +% @as(u32, @intCast(len - 1));
        for ([_]u32{ address, last }) |at| {
            if (self.source.of(at) != .non_secure) {
                self.refused = address;
                return true;
            }
        }
        return false;
    }
};
