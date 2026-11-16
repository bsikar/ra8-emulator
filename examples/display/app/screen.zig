//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The screens the UI has, and the one switch that builds each.

const tree = @import("tree.zig");
const State = @import("state.zig").State;
const Services = @import("data/services.zig").Services;

pub const Id = enum {
    sleep,
    lock,
    home,
    library,
    listen,
    player,
    equalizer,
    apps,
    settings,
    passcode,
    date_time,
    book_reader,
    reading_menu,
    mdl_explore,
    mdl_search,
    mdl_work,
    mdl_sources,
    mdl_comic,
    mdl_library,
    mdl_activity,
    mdl_settings,
    mdl_source_list,
};

/// What a screen is built from: the UI's own state and the services.
pub const Ctx = struct {
    state: *const State,
    svc: Services,
};

pub fn build(id: Id, b: *tree.Builder, ctx: Ctx) tree.Error!tree.Widget {
    return switch (id) {
        .sleep => @import("screens/sleep.zig").build(b, ctx),
        .lock => @import("screens/lock.zig").build(b, ctx),
        .home => @import("screens/home.zig").build(b, ctx),
        .library => @import("screens/library.zig").build(b, ctx),
        .listen => @import("screens/listen.zig").build(b, ctx),
        .player => @import("screens/player.zig").build(b, ctx),
        .equalizer => @import("screens/equalizer.zig").build(b, ctx),
        .apps => @import("screens/apps.zig").build(b, ctx),
        .settings => @import("screens/settings.zig").build(b, ctx),
        .passcode => @import("screens/passcode.zig").build(b, ctx),
        .date_time => @import("screens/date_time.zig").build(b, ctx),
        .book_reader => @import("screens/book_reader.zig").build(b, ctx),
        .reading_menu => @import("screens/reading_menu.zig").build(b, ctx),
        .mdl_explore => @import("screens/mdl_explore.zig").build(b, ctx),
        .mdl_search => @import("screens/mdl_search.zig").build(b, ctx),
        .mdl_work => @import("screens/mdl_work.zig").build(b, ctx),
        .mdl_sources => @import("screens/mdl_sources.zig").build(b, ctx),
        .mdl_comic => @import("screens/mdl_comic.zig").build(b, ctx),
        .mdl_library => @import("screens/mdl_library.zig").build(b, ctx),
        .mdl_activity => @import("screens/mdl_activity.zig").build(b, ctx),
        .mdl_settings => @import("screens/mdl_settings.zig").build(b, ctx),
        .mdl_source_list => @import("screens/mdl_source_list.zig").build(b, ctx),
    };
}
