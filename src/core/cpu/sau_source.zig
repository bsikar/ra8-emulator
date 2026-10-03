//! The board's SAU as the Zig core's attribution source (RA8EMU-352).
//!
//! The firmware programs the SAU the board keeps (src/periph/sau.zig); this
//! answers the core's two questions from it: which state a fetched address
//! belongs to (SG, the INVEP check) and what TT reports for a target.
//! The IDAU is the default one, as in src/core/tt.zig.
const sau = @import("../../periph/sau.zig");
const sau_attr = @import("../../periph/sau_attr.zig");
const tt = @import("../tt.zig");
const attribution = @import("attribution.zig");

pub const SauSource = struct {
    unit: *const sau.Sau,

    pub fn source(self: *SauSource) attribution.Attribution {
        return .{ .context = self, .stateFn = state, .respondFn = respond };
    }

    /// An exempt address takes the accessing state. The core asks this
    /// only for a Non-secure fetch, so exempt answers Non-secure.
    fn state(context: *anyopaque, address: u32) attribution.State {
        const self: *SauSource = @ptrCast(@alignCast(context));
        const answer = sau_attr.attribute(self.unit, .{}, address);
        return if (answer.exempt) .non_secure else answer.state;
    }

    fn respond(context: *anyopaque, target: u32, secure: bool) u32 {
        const self: *SauSource = @ptrCast(@alignCast(context));
        return tt.respond(self.unit, target, secure);
    }
};
