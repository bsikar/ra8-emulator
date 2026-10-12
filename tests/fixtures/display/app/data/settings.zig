//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What the UI asks device settings for: on/off flags it can flip, the
//! reader's typography choices, and the read-only values a row shows.

pub const Flag = enum {
    passcode_lock,
    media_when_locked,
    erase_after_wrong,
    time_from_wifi,
    clock_24h,
    time_in_reader,
    mdl_adult,
};

/// A reading-menu choice, stored as the index of the selected option.
pub const Choice = enum {
    size,
    face,
    spacing,
    margin,
    refresh,
};

pub const Info = enum {
    wifi,
    audio_output,
    page_refresh,
    time_zone,
    date_format,
    sleep_after,
    storage,
    software,
    passcode_type,
    require_passcode,
};

pub const Settings = struct {
    ctx: *anyopaque,
    ops: *const Ops,

    pub const Ops = struct {
        flag: *const fn (ctx: *anyopaque, which: Flag) bool,
        setFlag: *const fn (ctx: *anyopaque, which: Flag, value: bool) void,
        choice: *const fn (ctx: *anyopaque, which: Choice) u8,
        setChoice: *const fn (ctx: *anyopaque, which: Choice, value: u8) void,
        info: *const fn (ctx: *anyopaque, which: Info) [:0]const u8,
    };

    pub fn flag(self: Settings, which: Flag) bool {
        return self.ops.flag(self.ctx, which);
    }
    pub fn setFlag(self: Settings, which: Flag, value: bool) void {
        self.ops.setFlag(self.ctx, which, value);
    }
    pub fn choice(self: Settings, which: Choice) u8 {
        return self.ops.choice(self.ctx, which);
    }
    pub fn setChoice(self: Settings, which: Choice, value: u8) void {
        self.ops.setChoice(self.ctx, which, value);
    }
    pub fn info(self: Settings, which: Info) [:0]const u8 {
        return self.ops.info(self.ctx, which);
    }
};
