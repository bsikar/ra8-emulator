//! Where the Zig core asks which security state an address belongs to
//! (RA8EMU-357).
//!
//! The board builds one from src/periph/sau_attr.zig, which combines the SAU
//! with the IDAU. A core with no source treats every address as Secure, the
//! way it behaved before this seam existed, so nothing changes for a board
//! that does not set one.
const sau_attr = @import("../../periph/sau_attr.zig");

pub const State = sau_attr.State;

pub const Attribution = struct {
    context: *anyopaque,
    stateFn: *const fn (context: *anyopaque, address: u32) State,

    pub fn of(self: Attribution, address: u32) State {
        return self.stateFn(self.context, address);
    }
};

/// The state `address` belongs to, or Secure when there is no source.
pub fn state(source: ?Attribution, address: u32) State {
    return if (source) |s| s.of(address) else .secure;
}
