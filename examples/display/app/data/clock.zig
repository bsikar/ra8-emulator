//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What the UI asks a clock for. The fake answers one fixed moment; a real
//! clock replaces it without a screen changing.

pub const Moment = struct {
    time: [:0]const u8,
    short_date: [:0]const u8,
    long_date: [:0]const u8,
    day: [:0]const u8,
};

pub const Clock = struct {
    ctx: *anyopaque,
    ops: *const Ops,

    pub const Ops = struct {
        now: *const fn (ctx: *anyopaque) Moment,
    };

    pub fn now(self: Clock) Moment {
        return self.ops.now(self.ctx);
    }
};

pub const Fake = struct {
    moment: Moment = .{
        .time = "14:05",
        .short_date = "Sat 3 Oct",
        .long_date = "Saturday, 3 October 2026",
        .day = "Saturday, 3 October",
    },

    pub fn service(self: *Fake) Clock {
        return .{ .ctx = self, .ops = &.{ .now = now } };
    }

    fn now(ctx: *anyopaque) Moment {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        return self.moment;
    }
};
