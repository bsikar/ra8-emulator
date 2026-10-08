//! The menu bar's model (RA8EMU-967, RA8EMU-957): one description of the
//! menus that every backend renders its own way, the macOS system bar, a
//! Win32 menu on the window, or the strip our widgets draw on Linux. Items
//! are added here once; a backend only draws them and reports which action
//! fired. SDL3 has no menu API, so the backends sit behind the platform
//! seam (docs/adr/0001-gui-stack.md).
const std = @import("std");
const pane_layout = @import("pane_layout.zig");
const shell_frame = @import("shell_frame.zig");

const Kind = pane_layout.Kind;

/// The fixed commands. Run, Pause and Step are the time bar's controls.
pub const Command = enum { open_elf, close, quit, run, pause, step, reset };

pub const Action = union(enum) {
    command: Command,
    /// Show or hide a pane of this kind.
    toggle: Kind,

    pub fn eql(self: Action, other: Action) bool {
        return switch (self) {
            .command => |command| other == .command and other.command == command,
            .toggle => |kind| other == .toggle and other.toggle == kind,
        };
    }
};

/// A key pressed with the platform's primary modifier held: Cmd on macOS,
/// Ctrl everywhere else. The key is an uppercase letter or a digit.
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
    .{ .label = "Close", .action = .{ .command = .close }, .shortcut = .{ .key = 'W' } },
    .{ .label = "Quit", .action = .{ .command = .quit }, .shortcut = .{ .key = 'Q' }, .divided = true },
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
    var items: [kinds.len - 1]Item = undefined;
    var next: usize = 0;
    for (kinds) |kind| {
        if (kind == .empty) continue;
        items[next] = .{
            .label = shell_frame.kindName(kind),
            .action = .{ .toggle = kind },
            .shortcut = .{ .key = '1' + next },
        };
        next += 1;
    }
    break :views items;
};

pub const bar = [_]Menu{
    .{ .title = "File", .items = &file },
    .{ .title = "Run", .items = &run },
    .{ .title = "View", .items = &view },
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
};

/// Whether `action` can fire now. Disabled items draw muted and never fire.
pub fn enabled(action: Action, state: State) bool {
    return switch (action) {
        .toggle => true,
        .command => |command| switch (command) {
            .open_elf, .quit => true,
            .close, .reset => state.loaded,
            .run, .step => state.loaded and !state.running,
            .pause => state.running,
        },
    };
}
