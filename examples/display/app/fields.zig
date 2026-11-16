//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The values a toggle, segmented control or pager edits on its own. The
//! widget changes its descriptor when tapped; the app reads the descriptor
//! back through a binding keyed by one of these and stores the new value.

pub const Field = enum(u8) {
    library_filter,
    library_page,
    listen_tab,
    eq_preset,
    apps_page,
    passcode_lock,
    media_when_locked,
    erase_after_wrong,
    time_from_wifi,
    clock_24h,
    time_in_reader,
    reading_size,
    reading_face,
    reading_spacing,
    reading_margin,
    reading_refresh,
    explore_tab,
    explore_page,
    search_page,
    work_page,
    sources_page,
    mdl_library_filter,
    mdl_library_page,
    activity_page,
    mdl_adult,
    source_enabled,
    source_page,
};

/// One value a widget changed since the last sync.
pub const Change = struct {
    field: Field,
    index: u8,
    value: u16,
};

/// True when other widgets on the screen show something derived from this
/// field, so the tree has to be rebuilt after it changes. A field that only
/// its own widget shows needs no more than that widget's own redraw.
pub fn rebuilds(field: Field) bool {
    return switch (field) {
        .passcode_lock,
        .media_when_locked,
        .erase_after_wrong,
        .time_from_wifi,
        .clock_24h,
        .time_in_reader,
        .mdl_adult,
        .listen_tab,
        .reading_spacing,
        .reading_margin,
        .reading_refresh,
        => false,
        else => true,
    };
}
