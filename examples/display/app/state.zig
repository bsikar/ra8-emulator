//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! What the UI itself remembers: where the user is and what each screen's
//! controls are set to. Anything that belongs to the device or its content
//! lives behind a service instead.

const nav = @import("nav.zig");

pub const passcode_length: u8 = 6;

pub const State = struct {
    stack: nav.Stack = nav.Stack.init(.home),
    passcode_digits: u8 = 0,
    library_filter: u8 = 0,
    library_page: u16 = 0,
    listen_tab: u8 = 0,
    apps_page: u16 = 0,
    explore_tab: u8 = 0,
    explore_page: u16 = 0,
    search_page: u16 = 0,
    work_page: u16 = 0,
    sources_page: u16 = 0,
    mdl_library_filter: u8 = 0,
    mdl_library_page: u16 = 0,
    activity_page: u16 = 0,
    source_page: u16 = 0,
};
