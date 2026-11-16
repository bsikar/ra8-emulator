//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What the UI asks the music player for: the track on now, the transport,
//! the volume, the equalizer, and what there is to browse.

pub const Track = struct {
    title: [:0]const u8,
    artist: [:0]const u8,
    album: [:0]const u8,
    number: u16,
    of: u16,
    minute: u16,
    minutes: u16,
};

pub const Shelf = struct {
    label: [:0]const u8,
    count: [:0]const u8,
};

pub const Played = struct {
    title: [:0]const u8,
    meta: [:0]const u8,
};

pub const volume_steps: u8 = 12;
pub const band_count: usize = 7;
pub const band_limit: i8 = 6;
pub const preset_names = [_][:0]const u8{ "Flat", "Bass", "Treble", "Voice", "Custom" };
pub const custom_preset: u8 = 4;
pub const band_names = [band_count][:0]const u8{ "Bass 60", "150", "400", "1 k", "2.5 k", "6 k", "Treble 12 k" };

pub const Player = struct {
    ctx: *anyopaque,
    ops: *const Ops,

    pub const Ops = struct {
        track: *const fn (ctx: *anyopaque) Track,
        playing: *const fn (ctx: *anyopaque) bool,
        togglePlaying: *const fn (ctx: *anyopaque) void,
        step: *const fn (ctx: *anyopaque, delta: i32) void,
        volume: *const fn (ctx: *anyopaque) u8,
        nudgeVolume: *const fn (ctx: *anyopaque, delta: i32) void,
        preset: *const fn (ctx: *anyopaque) u8,
        setPreset: *const fn (ctx: *anyopaque, preset: u8) void,
        band: *const fn (ctx: *anyopaque, index: usize) i8,
        nudgeBand: *const fn (ctx: *anyopaque, index: usize, delta: i8) void,
        shelves: *const fn (ctx: *anyopaque) []const Shelf,
        played: *const fn (ctx: *anyopaque) []const Played,
    };

    pub fn track(self: Player) Track {
        return self.ops.track(self.ctx);
    }
    pub fn playing(self: Player) bool {
        return self.ops.playing(self.ctx);
    }
    pub fn togglePlaying(self: Player) void {
        self.ops.togglePlaying(self.ctx);
    }
    /// Move `delta` tracks through the queue, wrapping at either end.
    pub fn step(self: Player, delta: i32) void {
        self.ops.step(self.ctx, delta);
    }
    pub fn volume(self: Player) u8 {
        return self.ops.volume(self.ctx);
    }
    pub fn nudgeVolume(self: Player, delta: i32) void {
        self.ops.nudgeVolume(self.ctx, delta);
    }
    pub fn preset(self: Player) u8 {
        return self.ops.preset(self.ctx);
    }
    pub fn setPreset(self: Player, value: u8) void {
        self.ops.setPreset(self.ctx, value);
    }
    pub fn band(self: Player, index: usize) i8 {
        return self.ops.band(self.ctx, index);
    }
    /// Move one band a step and mark the preset as custom.
    pub fn nudgeBand(self: Player, index: usize, delta: i8) void {
        self.ops.nudgeBand(self.ctx, index, delta);
    }
    pub fn shelves(self: Player) []const Shelf {
        return self.ops.shelves(self.ctx);
    }
    pub fn played(self: Player) []const Played {
        return self.ops.played(self.ctx);
    }
};
