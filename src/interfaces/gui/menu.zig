//! The menu bar's model (RA8EMU-967, RA8EMU-957): one description of the
//! menus that every backend renders its own way, the macOS system bar, a
//! Win32 menu on the window, or the strip our widgets draw on Linux. Items
//! are added here once; a backend only draws them and reports which action
//! fired. SDL3 has no menu API, so the backends sit behind the platform
//! seam (docs/adr/0001-gui-stack.md).
const std = @import("std");
const pane_layout = @import("ui/pane_layout.zig");
const shell_frame = @import("ui/shell/frame.zig");
pub const board_profiles = @import("shell/board_profiles.zig");

const Kind = pane_layout.Kind;

/// The fixed commands. Run, Pause and Step are the time bar's controls.
pub const Command = enum { open_elf, open_profile, close, settings, quit, run, pause, step, reset, toggle_fullscreen, reload };

/// Pick a shipped board or panel profile (RA8EMU-1152). An empty panel
/// stem means the board's own panel, "none" means no panel at all.
pub const Choice = struct {
    kind: enum { board, panel },
    stem: []const u8,
};

pub const Action = union(enum) {
    command: Command,
    /// Show or hide a pane of this kind.
    toggle: Kind,
    /// Open the shipped profile the choice names (RA8EMU-1152).
    choice: Choice,
    /// The recent image the File drop-down numbered (RA8EMU-1153), newest
    /// first.
    recent: usize,

    pub fn eql(self: Action, other: Action) bool {
        return switch (self) {
            .command => |command| other == .command and other.command == command,
            .toggle => |kind| other == .toggle and other.toggle == kind,
            .choice => |choice| other == .choice and other.choice.kind == choice.kind and std.mem.eql(u8, other.choice.stem, choice.stem),
            .recent => |at| other == .recent and other.recent == at,
        };
    }
};

/// A key pressed with the platform's primary modifier held: Cmd on macOS,
/// Ctrl everywhere else. The key is an uppercase letter, a digit or the
/// comma.
pub const Shortcut = struct {
    key: u8,
    shift: bool = false,
};

pub const Item = struct {
    label: []const u8,
    action: Action,
    shortcut: ?Shortcut = null,
    /// A divider line sits above this item.
    divided: bool = false,
};

pub const Menu = struct {
    title: []const u8,
    items: []const Item,
};

pub const file = [_]Item{
    .{ .label = "Open ELF...", .action = .{ .command = .open_elf }, .shortcut = .{ .key = 'O' } },
    .{ .label = "Reload", .action = .{ .command = .reload } },
    .{ .label = "Close", .action = .{ .command = .close }, .shortcut = .{ .key = 'W' } },
    .{ .label = "Settings...", .action = .{ .command = .settings }, .shortcut = .{ .key = ',' } },
    .{ .label = "Quit", .action = .{ .command = .quit }, .shortcut = .{ .key = 'Q' }, .divided = true },
};

/// The shipped board profiles and panel profiles (RA8EMU-1152), then the
/// OS picker for a profile of one's own.
pub const board = board_menu: {
    var items: [1 + board_profiles.panels.len + 1]Item = undefined;
    var next: usize = 0;
    items[next] = .{
        .label = "Board: EK-RA8D2",
        .action = .{ .choice = .{ .kind = .board, .stem = board_profiles.default_board } },
        .divided = next > 0,
    };
    next += 1;
    for (&board_profiles.panels) |*panel| {
        items[next] = .{
            .label = std.fmt.comptimePrint("Panel: {s}", .{panel.label}),
            .action = .{ .choice = .{ .kind = .panel, .stem = panel.stem } },
        };
        next += 1;
    }
    items[next] = .{ .label = "Open Profile...", .action = .{ .command = .open_profile }, .divided = true };
    break :board_menu items;
};

pub const run = [_]Item{
    .{ .label = "Run", .action = .{ .command = .run }, .shortcut = .{ .key = 'R' } },
    .{ .label = "Pause", .action = .{ .command = .pause }, .shortcut = .{ .key = 'P' } },
    .{ .label = "Step", .action = .{ .command = .step }, .shortcut = .{ .key = 'S' } },
    .{ .label = "Reset", .action = .{ .command = .reset }, .shortcut = .{ .key = 'R', .shift = true }, .divided = true },
};

/// One toggle per pane kind, in Kind order, on Cmd/Ctrl+1 and up.
pub const view = views: {
    const kinds = std.enums.values(Kind);
    var items: [kinds.len]Item = undefined;
    var next: usize = 0;
    for (kinds) |kind| {
        if (kind == .empty) continue;
        items[next] = .{
            .label = shell_frame.kindName(kind),
            .action = .{ .toggle = kind },
            // Ctrl/Cmd+1..9 for the first nine panes; a tenth toggles unkeyed.
            .shortcut = if (next < 9) .{ .key = '1' + next } else null,
        };
        next += 1;
    }
    // Full screen is the View menu's own entry under a divider (RA8EMU-966);
    // the F11 and Ctrl+Cmd+F keys are the window's, not the model's.
    items[next] = .{
        .label = "Enter Full Screen",
        .action = .{ .command = .toggle_fullscreen },
        .divided = true,
    };
    break :views items;
};

pub const bar = [_]Menu{
    .{ .title = "File", .items = &file },
    .{ .title = "Run", .items = &run },
    .{ .title = "View", .items = &view },
    .{ .title = "Board", .items = &board },
};

pub const Modifier = enum {
    command,
    control,

    pub fn label(self: Modifier) []const u8 {
        return switch (self) {
            .command => "Cmd",
            .control => "Ctrl",
        };
    }
};

/// The primary modifier on `os`.
pub fn modifier(os: std.Target.Os.Tag) Modifier {
    return if (os == .macos) .command else .control;
}

/// "Cmd+O", "Ctrl+Shift+R": the shortcut as the Windows menu and the
/// in-window strip print it. macOS draws its own key equivalents.
pub fn text(shortcut: Shortcut, os: std.Target.Os.Tag, buf: []u8) std.fmt.BufPrintError![]u8 {
    const shift: []const u8 = if (shortcut.shift) "Shift+" else "";
    return std.fmt.bufPrint(buf, "{s}+{s}{c}", .{ modifier(os).label(), shift, shortcut.key });
}

/// Whether `item` shows on `os`. macOS keeps Quit in the app menu the
/// system builds, so File leaves it out there.
pub fn shows(item: Item, os: std.Target.Os.Tag) bool {
    return !(os == .macos and item.action.eql(.{ .command = .quit }));
}

/// The action bound to `key` (any case) with the primary modifier held,
/// and Shift when `shift`; null when nothing is bound to it.
pub fn find(menus: []const Menu, key: u8, shift: bool) ?Action {
    const upper = std.ascii.toUpper(key);
    for (menus) |menu| {
        for (menu.items) |item| {
            const bound = item.shortcut orelse continue;
            if (bound.key == upper and bound.shift == shift) return item.action;
        }
    }
    return null;
}

/// What the enabled rules read from the session.
pub const State = struct {
    /// An ELF is loaded.
    loaded: bool = false,
    /// The cores are running rather than halted.
    running: bool = false,
    /// The window is full screen (RA8EMU-966).
    fullscreen: bool = false,
};

/// The text `item` draws: "Enter"/"Exit Full Screen" follows the window's
/// state (RA8EMU-966); every other item keeps its own label.
pub fn label(item: Item, state: State) []const u8 {
    switch (item.action) {
        .command => |command| {
            if (command == .toggle_fullscreen) {
                return if (state.fullscreen) "Exit Full Screen" else "Enter Full Screen";
            }
        },
        .toggle, .choice, .recent => {},
    }
    return item.label;
}

/// Whether `action` can fire now. Disabled items draw muted and never fire.
pub fn enabled(action: Action, state: State) bool {
    return switch (action) {
        .toggle, .choice, .recent => true,
        .command => |command| switch (command) {
            .open_elf, .open_profile, .settings, .quit, .toggle_fullscreen => true,
            .close, .reset, .reload => state.loaded,
            .run, .step => state.loaded and !state.running,
            .pause => state.running,
        },
    };
}
