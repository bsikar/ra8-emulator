//! Which word of the PPB an SCS access from the Zig core lands on, by the
//! Security state of the core making it (RA8EMU-272).
//!
//! The rules are src/periph/scs_alias.zig (which bank the access names) and
//! src/periph/scb_bank.zig (where that bank's copy lives). Secure code on
//! the normal window reaches the Secure copy and on the alias window the
//! Non-secure one; Non-secure code on the normal window reaches the
//! Non-secure copy, and on the alias window reads zero and writes nothing.
//!
//! A register banked bit by bit, or one the bank table does not list yet,
//! keeps the address it was given: its field split is RA8EMU-365.

const alias = @import("../../periph/scs_alias.zig");
const scb_bank = @import("../../periph/scb_bank.zig");
const banked = @import("../banked.zig");

pub const Landing = union(enum) {
    /// The access goes to this address.
    at: u32,
    /// Non-secure code on the alias window: reads zero, writes are dropped.
    res0,
};

/// Where an access to `address` lands. A core with no state given is taken
/// as Secure, which is how every core runs until it changes state.
pub fn land(state: ?*const banked.Banked, address: u32) Landing {
    const secure = if (state) |s| s.current == .secure else true;
    return switch (alias.route(address, secure)) {
        .outside => .{ .at = address },
        .res0 => .res0,
        .register => |target| .{ .at = copy(target, address) },
    };
}

fn copy(target: alias.Target, address: u32) u32 {
    const word = target.address & ~@as(u32, 3);
    const within = target.address - word;
    return switch (scb_bank.backing(.{ .address = word, .view = target.view })) {
        .word => |at| at + within,
        .bit_by_bit, .unknown => address,
    };
}
