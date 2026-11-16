//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Settings held in memory, with the defaults the design shows.

const std = @import("std");
const settings = @import("settings.zig");

const refresh_names = [_][:0]const u8{ "Rarely", "Every 8 pages", "Every page" };

pub const Fake = struct {
    flags: std.EnumArray(settings.Flag, bool) = std.EnumArray(settings.Flag, bool).init(.{
        .passcode_lock = true,
        .media_when_locked = true,
        .erase_after_wrong = false,
        .time_from_wifi = true,
        .clock_24h = true,
        .time_in_reader = true,
        .mdl_adult = false,
    }),
    choices: std.EnumArray(settings.Choice, u8) = std.EnumArray(settings.Choice, u8).init(.{
        .size = 3,
        .face = 0,
        .spacing = 1,
        .margin = 1,
        .refresh = 1,
    }),

    pub fn service(self: *Fake) settings.Settings {
        return .{ .ctx = self, .ops = &.{ .flag = flag, .setFlag = setFlag, .choice = choice, .setChoice = setChoice, .info = info } };
    }

    fn from(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }

    fn flag(ctx: *anyopaque, which: settings.Flag) bool {
        return from(ctx).flags.get(which);
    }

    fn setFlag(ctx: *anyopaque, which: settings.Flag, value: bool) void {
        from(ctx).flags.set(which, value);
    }

    fn choice(ctx: *anyopaque, which: settings.Choice) u8 {
        return from(ctx).choices.get(which);
    }

    fn setChoice(ctx: *anyopaque, which: settings.Choice, value: u8) void {
        from(ctx).choices.set(which, value);
    }

    fn info(ctx: *anyopaque, which: settings.Info) [:0]const u8 {
        return switch (which) {
            .wifi => "[NETWORK NAME]",
            .audio_output => "Wired headphones",
            .page_refresh => refresh_names[from(ctx).choices.get(.refresh)],
            .time_zone => "[TIME ZONE]",
            .date_format => "3 October 2026",
            .sleep_after => "10 minutes",
            .storage => "Encrypted - 2.1 GB used",
            .software => "[FIRMWARE VERSION]",
            .passcode_type => "6 digits",
            .require_passcode => "After 5 minutes asleep",
        };
    }
};
