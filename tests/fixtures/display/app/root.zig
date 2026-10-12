//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! The UI module's index: what a host test or the board image imports.

pub const App = @import("app.zig").App;
pub const Key = @import("app.zig").Key;
pub const Damage = @import("app.zig").Damage;
pub const Canvas = @import("paint.zig").Canvas;
pub const Services = @import("data/services.zig").Services;
pub const Fakes = @import("data/services.zig").Fakes;
pub const State = @import("state.zig").State;
pub const Stack = @import("nav.zig").Stack;

pub const actions = @import("actions.zig");
pub const compose = @import("compose.zig");
pub const diff = @import("diff.zig");
pub const fields = @import("fields.zig");
pub const names = @import("names.zig");
pub const nav = @import("nav.zig");
pub const paint = @import("paint.zig");
pub const route = @import("route.zig");
pub const screen = @import("screen.zig");
pub const state = @import("state.zig");
pub const theme = @import("theme.zig");
pub const tree = @import("tree.zig");
