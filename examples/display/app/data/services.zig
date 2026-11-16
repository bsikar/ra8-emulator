//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! Everything a screen may ask of the world outside the UI, as one bundle of
//! small interfaces. `Fakes` is the stub bundle the UI runs on today.

const clock = @import("clock.zig");
const library = @import("library.zig");
const player = @import("player.zig");
const settings = @import("settings.zig");
const mdl = @import("mdl.zig");
const fake_library = @import("fake_library.zig");
const fake_player = @import("fake_player.zig");
const fake_settings = @import("fake_settings.zig");
const fake_mdl = @import("fake_mdl.zig");

pub const Services = struct {
    clock: clock.Clock,
    library: library.Library,
    player: player.Player,
    settings: settings.Settings,
    mdl: mdl.Mdl,
};

pub const Fakes = struct {
    clock: clock.Fake = .{},
    library: fake_library.Fake = .{},
    player: fake_player.Fake = .{},
    settings: fake_settings.Fake = .{},
    mdl: fake_mdl.Fake = .{},

    pub fn services(self: *Fakes) Services {
        return .{
            .clock = self.clock.service(),
            .library = self.library.service(),
            .player = self.player.service(),
            .settings = self.settings.service(),
            .mdl = self.mdl.service(),
        };
    }
};
