//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Where every input leads. One place decides what an action, a changed
//! control, a reader tap zone or the power key does to the screen stack and
//! the services, so no screen needs to know about any other.

const std = @import("std");
const actions = @import("actions.zig");
const fields = @import("fields.zig");
const screen = @import("screen.zig");
const state_mod = @import("state.zig");
const theme = @import("theme.zig");
const Services = @import("data/services.zig").Services;

const State = state_mod.State;

const shell_roots = [_]screen.Id{ .home, .library, .listen, .apps, .settings };
const mdl_roots = [_]screen.Id{ .mdl_explore, .mdl_library, .mdl_activity, .mdl_search, .mdl_settings };

/// The reader's three tap zones, from the design: previous, menu, next.
pub const zones = struct {
    pub const menu_from: i32 = 268;
    pub const next_from: i32 = 590;
};

pub const keypad = struct {
    pub const delete: u16 = 10;
};

const setting_targets = [_]?screen.Id{ null, .player, .reading_menu, .equalizer, .passcode, .date_time, null, null };

/// A tap on a full-page reader is a zone, not a widget. True when `x`
/// landed on one and the screen needs rebuilding.
pub fn zone(state: *State, svc: Services, x: i32) bool {
    const step: i32 = if (x < zones.menu_from) -1 else if (x >= zones.next_from) 1 else 0;
    switch (state.stack.top()) {
        .book_reader => if (step == 0) state.stack.push(.reading_menu) else svc.library.turn(step),
        .mdl_comic => if (step == 0) state.stack.back(.home) else svc.mdl.turn(step),
        else => return false,
    }
    return true;
}

fn unlock(state: *State) void {
    state.passcode_digits = 0;
    if (!state.stack.pop()) state.stack.root(.home);
}

fn key(state: *State, index: u16) void {
    if (index == keypad.delete) {
        state.passcode_digits -|= 1;
        return;
    }
    state.passcode_digits += 1;
    if (state.passcode_digits == state_mod.passcode_length) unlock(state);
}

fn openEntry(state: *State, svc: Services, index: u16, recent: bool) void {
    const entries = if (recent) svc.library.recent() else svc.library.shelf();
    if (index >= entries.len) return;
    state.stack.push(switch (entries[index].kind) {
        .book => .book_reader,
        .comic => if (recent) .mdl_comic else .mdl_work,
        .audio => .player,
    });
}

/// Carry out one posted action. True when the screen must be rebuilt.
pub fn act(state: *State, svc: Services, event: actions.Event) bool {
    const stack = &state.stack;
    switch (event.id) {
        .none, .inert, .search_go => return false,
        .go_home => stack.root(.home),
        .back => stack.back(.home),
        .shell_tab => if (event.index < shell_roots.len) stack.root(shell_roots[event.index]),
        .mdl_tab => if (event.index < mdl_roots.len) stack.within(.home, mdl_roots[event.index]),
        .open_player, .open_listen_row => stack.push(.player),
        .play_pause => svc.player.togglePlaying(),
        .skip => svc.player.step(1),
        .previous => svc.player.step(-1),
        .resume_book => stack.push(.book_reader),
        .open_recent => openEntry(state, svc, event.index, true),
        .open_library_item => openEntry(state, svc, event.index, false),
        .open_app => if (event.index == 0) stack.push(.mdl_explore) else return false,
        .all_apps => stack.root(.apps),
        .open_equalizer => stack.push(.equalizer),
        .volume_down => svc.player.nudgeVolume(-1),
        .volume_up => svc.player.nudgeVolume(1),
        .eq_reset => svc.player.setPreset(0),
        .band_down => svc.player.nudgeBand(event.index, -1),
        .band_up => svc.player.nudgeBand(event.index, 1),
        .open_setting => {
            const target = if (event.index < setting_targets.len) setting_targets[event.index] else null;
            stack.push(target orelse return false);
        },
        .open_lock => stack.push(.lock),
        .key => key(state, event.index),
        .reader_done => stack.back(.home),
        .reader_library => stack.root(.library),
        .open_work => stack.push(.mdl_work),
        .continue_chapter, .read_source => stack.push(.mdl_comic),
        .open_job => {
            const jobs = svc.mdl.jobs();
            if (event.index >= jobs.len or !std.mem.eql(u8, jobs[event.index].action, "Open")) return false;
            stack.push(.mdl_comic);
        },
        .open_chapter => stack.push(.mdl_sources),
        .open_source_list => stack.push(.mdl_source_list),
    }
    return true;
}

fn setIfChanged(comptime T: type, slot: *T, value: u16) bool {
    const next: T = @intCast(value);
    if (slot.* == next) return false;
    slot.* = next;
    return true;
}

/// A new filter starts again from its first page.
fn resetPage(changed: bool, page: *u16) bool {
    if (changed) page.* = 0;
    return changed;
}

fn flag(svc: Services, which: anytype, value: u16) bool {
    const next = value != 0;
    if (svc.settings.flag(which) == next) return false;
    svc.settings.setFlag(which, next);
    return true;
}

fn choice(svc: Services, which: anytype, value: u16) bool {
    const next: u8 = @intCast(value);
    if (svc.settings.choice(which) == next) return false;
    svc.settings.setChoice(which, next);
    return true;
}

/// Store one value a widget changed. True when it differs from what was
/// stored before.
pub fn store(state: *State, svc: Services, change: fields.Change) bool {
    return switch (change.field) {
        .library_filter => resetPage(setIfChanged(u8, &state.library_filter, change.value), &state.library_page),
        .library_page => setIfChanged(u16, &state.library_page, change.value),
        .listen_tab => setIfChanged(u8, &state.listen_tab, change.value),
        .apps_page => setIfChanged(u16, &state.apps_page, change.value),
        .explore_tab => resetPage(setIfChanged(u8, &state.explore_tab, change.value), &state.explore_page),
        .explore_page => setIfChanged(u16, &state.explore_page, change.value),
        .search_page => setIfChanged(u16, &state.search_page, change.value),
        .work_page => setIfChanged(u16, &state.work_page, change.value),
        .sources_page => setIfChanged(u16, &state.sources_page, change.value),
        .mdl_library_filter => resetPage(setIfChanged(u8, &state.mdl_library_filter, change.value), &state.mdl_library_page),
        .mdl_library_page => setIfChanged(u16, &state.mdl_library_page, change.value),
        .activity_page => setIfChanged(u16, &state.activity_page, change.value),
        .source_page => setIfChanged(u16, &state.source_page, change.value),
        .passcode_lock => flag(svc, .passcode_lock, change.value),
        .media_when_locked => flag(svc, .media_when_locked, change.value),
        .erase_after_wrong => flag(svc, .erase_after_wrong, change.value),
        .time_from_wifi => flag(svc, .time_from_wifi, change.value),
        .clock_24h => flag(svc, .clock_24h, change.value),
        .time_in_reader => flag(svc, .time_in_reader, change.value),
        .mdl_adult => flag(svc, .mdl_adult, change.value),
        .reading_size => choice(svc, .size, change.value),
        .reading_face => choice(svc, .face, change.value),
        .reading_spacing => choice(svc, .spacing, change.value),
        .reading_margin => choice(svc, .margin, change.value),
        .reading_refresh => choice(svc, .refresh, change.value),
        .eq_preset => blk: {
            if (svc.player.preset() == change.value) break :blk false;
            svc.player.setPreset(@intCast(change.value));
            break :blk true;
        },
        .source_enabled => blk: {
            const next = change.value != 0;
            if (svc.mdl.sourceEnabled(change.index) == next) break :blk false;
            svc.mdl.setSourceEnabled(change.index, next);
            break :blk true;
        },
    };
}

/// The power key: sleep from anywhere, and wake to the lock screen (or
/// straight home when the passcode lock is off).
pub fn power(state: *State, svc: Services) void {
    if (state.stack.top() != .sleep) {
        state.stack.push(.sleep);
        return;
    }
    _ = state.stack.pop();
    state.passcode_digits = 0;
    if (svc.settings.flag(.passcode_lock)) state.stack.push(.lock);
}

comptime {
    if (zones.next_from >= theme.panel.width) @compileError("reader zones exceed the panel");
}
