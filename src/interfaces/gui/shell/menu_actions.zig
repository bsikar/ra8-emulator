//! The shell's menu actions (RA8EMU-957): the menu strip reports an action
//! from a pressed item (RA8EMU-968) and the shortcut keys bind the same
//! ones, so the shell takes each action in one place, the way its time
//! bar's buttons and its pane titles would.
const std = @import("std");
const platform = @import("../platform.zig");
const menu = @import("../menu.zig");
const menu_bar = @import("../menu_bar.zig");
const pane_layout = @import("../ui/pane_layout.zig");
const shell_loop = @import("loop.zig");

const Shell = shell_loop.Shell;

/// What the strip's enabled rules read from the session this frame.
pub fn observe(shell: *Shell, window: platform.Platform, width: i32) void {
    if (shell.recent_menu) |m| shell.menu.menus = m.sync();
    shell.width = width;
    shell.menu.state = .{
        .loaded = shell.loaded,
        .running = if (shell.time) |time| time.run.lit else false,
        .fullscreen = window.fullscreen(),
    };
}

/// A left press offered to the strip before the panes get it: a title opens
/// or switches a drop-down, a press anywhere else takes an open drop-down
/// closed, and a press off the closed strip falls through. Returns whether
/// the press was taken.
pub fn press(shell: *Shell, window: platform.Platform, x: i32, y: i32) bool {
    if (shell.settings.press(&shell.themes, shell.width, shell.height, x, y)) return true;
    switch (menu_bar.press(&shell.menu.bar, shell.menu, shell.width, x, y)) {
        .fire => |action| fire(shell, window, action),
        .taken => return true,
        .missed => {},
    }
    return false;
}

/// A key pressed with the primary modifier held (Cmd on macOS, Ctrl
/// elsewhere): the menu model binds letters and digits. Keys the menu does
/// not bind fall through. Returns whether the key was taken.
pub fn key(shell: *Shell, window: platform.Platform, event: platform.Event) bool {
    if (shell.settings.key(event)) return true;
    const pressed = switch (event) {
        .key => |pressed| pressed,
        else => return false,
    };
    if (!pressed.down or !pressed.primary) return false;
    const code = std.math.cast(u8, pressed.code) orelse return false;
    const action = menu.find(shell.menu.menus, code, pressed.shift) orelse return false;
    fire(shell, window, action);
    return true;
}

/// One menu action: the same steps the time bar's buttons and the pane
/// titles take.
pub fn fire(shell: *Shell, window: platform.Platform, action: menu.Action) void {
    switch (action) {
        .command => |command| switch (command) {
            .open_elf => if (shell.files) |files| files.ask(),
            .reload => if (shell.files) |files| if (shell.link) |link| files.reload(link, &shell.status),
            .open_profile => if (shell.pick) |pick| pick.ask(),
            .settings => shell.settings.ask(),
            // The wire has no unload or reset method yet; those items wait
            // for the methods to land.
            .close, .reset => {},
            .quit => shell.open = false,
            .toggle_fullscreen => window.toggleFullscreen(),
            .run => if (shell.time) |time| if (shell.link) |link| time.pressCommand(.run, link, &shell.status),
            .pause => if (shell.time) |time| if (shell.link) |link| time.pressCommand(.pause, link, &shell.status),
            .step => if (shell.time) |time| if (shell.link) |link| time.pressCommand(.step, link, &shell.status),
        },
        .choice => |choice| if (shell.pick) |pick| pick.choose(choice),
        .toggle => |kind| togglePane(shell, kind),
        .recent => |at| if (shell.recent_menu) |m| if (m.recents) |list| if (list.path(at)) |path| shell.openImage(path),
    }
}

/// Show or hide a pane of this kind: a shown leaf goes empty, the first
/// empty leaf takes the kind back.
fn togglePane(shell: *Shell, kind: pane_layout.Kind) void {
    for (0..shell.layout.nodes.items.len) |i| {
        const index: pane_layout.Index = @intCast(i);
        const pane = shell.layout.pane(index) orelse continue;
        if (pane.kind != kind) continue;
        shell.layout.setKind(index, .empty) catch return;
        return;
    }
    for (0..shell.layout.nodes.items.len) |i| {
        const index: pane_layout.Index = @intCast(i);
        const pane = shell.layout.pane(index) orelse continue;
        if (pane.kind != .empty) continue;
        shell.layout.setKind(index, kind) catch return;
        return;
    }
}
