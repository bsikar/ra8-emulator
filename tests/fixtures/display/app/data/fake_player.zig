//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! A player with one album queued and no audio behind it.

const player = @import("player.zig");

const songs = [_][:0]const u8{
    "Harbour Lights", "Tin and Tar",  "Low Water Signal",
    "Northerly",      "Glass Floats", "The Long Mole",
    "Ebb",            "Night Ferry",  "Slack Tide",
};

const presets = [_][player.band_count]i8{
    .{ 0, 0, 0, 0, 0, 0, 0 },
    .{ 5, 4, 2, 0, 0, 0, 0 },
    .{ 0, 0, 0, 0, 2, 4, 5 },
    .{ -2, -1, 1, 3, 3, 1, 0 },
};

const shelf_rows = [_]player.Shelf{
    .{ .label = "Playlists", .count = "6" },
    .{ .label = "Artists", .count = "48" },
    .{ .label = "Albums", .count = "112" },
    .{ .label = "Songs", .count = "1,340" },
};

const played_rows = [_]player.Played{
    .{ .title = "Glass Harbour", .meta = "Album - The Tin Lanterns - 9 songs" },
    .{ .title = "Late Shift", .meta = "Playlist - 31 songs" },
    .{ .title = "North of the Weir", .meta = "Album - Hollis Wren - 11 songs" },
};

pub const Fake = struct {
    song: u16 = 2,
    is_playing: bool = true,
    level: u8 = 7,
    eq_preset: u8 = 1,
    bands: [player.band_count]i8 = presets[1],

    pub fn service(self: *Fake) player.Player {
        return .{ .ctx = self, .ops = &.{
            .track = track,
            .playing = playing,
            .togglePlaying = togglePlaying,
            .step = step,
            .volume = volume,
            .nudgeVolume = nudgeVolume,
            .preset = preset,
            .setPreset = setPreset,
            .band = band,
            .nudgeBand = nudgeBand,
            .shelves = shelves,
            .played = played,
        } };
    }

    fn from(ctx: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx));
    }

    fn track(ctx: *anyopaque) player.Track {
        const self = from(ctx);
        return .{
            .title = songs[self.song],
            .artist = "The Tin Lanterns",
            .album = "Glass Harbour",
            .number = self.song + 1,
            .of = songs.len,
            .minute = 1,
            .minutes = 4,
        };
    }

    fn playing(ctx: *anyopaque) bool {
        return from(ctx).is_playing;
    }

    fn togglePlaying(ctx: *anyopaque) void {
        const self = from(ctx);
        self.is_playing = !self.is_playing;
    }

    fn step(ctx: *anyopaque, delta: i32) void {
        const self = from(ctx);
        const count: i32 = songs.len;
        self.song = @intCast(@mod(@as(i32, self.song) + delta, count));
    }

    fn volume(ctx: *anyopaque) u8 {
        return from(ctx).level;
    }

    fn nudgeVolume(ctx: *anyopaque, delta: i32) void {
        const self = from(ctx);
        const next = @as(i32, self.level) + delta;
        self.level = @intCast(@max(0, @min(next, @as(i32, player.volume_steps))));
    }

    fn preset(ctx: *anyopaque) u8 {
        return from(ctx).eq_preset;
    }

    fn setPreset(ctx: *anyopaque, value: u8) void {
        const self = from(ctx);
        self.eq_preset = value;
        if (value < presets.len) self.bands = presets[value];
    }

    fn band(ctx: *anyopaque, index: usize) i8 {
        return from(ctx).bands[index];
    }

    fn nudgeBand(ctx: *anyopaque, index: usize, delta: i8) void {
        const self = from(ctx);
        const next = self.bands[index] + delta;
        self.bands[index] = @max(-player.band_limit, @min(next, player.band_limit));
        self.eq_preset = player.custom_preset;
    }

    fn shelves(_: *anyopaque) []const player.Shelf {
        return &shelf_rows;
    }

    fn played(_: *anyopaque) []const player.Played {
        return &played_rows;
    }
};
