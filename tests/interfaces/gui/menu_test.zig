//! Host tests for the menu model (RA8EMU-967): the bar's menus and items,
//! shortcut text per OS, Quit moving to the macOS app menu, shortcut
//! lookup, and the enabled rules.
const std = @import("std");
const ra8 = @import("ra8");
const menu = ra8.gui.menu;

test "the bar has File, Run and View in that order" {
    try std.testing.expectEqual(@as(usize, 3), menu.bar.len);
    try std.testing.expectEqualStrings("File", menu.bar[0].title);
    try std.testing.expectEqualStrings("Run", menu.bar[1].title);
    try std.testing.expectEqualStrings("View", menu.bar[2].title);
}

test "File opens an ELF, closes it and quits" {
    try std.testing.expectEqualStrings("Open ELF...", menu.file[0].label);
    try std.testing.expect(menu.file[0].action.eql(.{ .command = .open_elf }));
    try std.testing.expect(menu.file[1].action.eql(.{ .command = .close }));
    try std.testing.expect(menu.file[2].action.eql(.{ .command = .quit }));
    try std.testing.expect(menu.file[2].divided);
}

test "View toggles every pane kind but empty" {
    try std.testing.expectEqual(@as(usize, 7), menu.view.len);
    try std.testing.expectEqualStrings("Board", menu.view[0].label);
    try std.testing.expect(menu.view[0].action.eql(.{ .toggle = .board }));
    try std.testing.expectEqualStrings("Disassembly", menu.view[6].label);
    try std.testing.expectEqual(@as(u8, '7'), menu.view[6].shortcut.?.key);
    for (menu.view) |item| try std.testing.expect(item.action.toggle != .empty);
}

test "no two items share a shortcut" {
    for (menu.bar, 0..) |a_menu, a_at| {
        for (a_menu.items, 0..) |a, a_item| {
            const a_key = a.shortcut orelse continue;
            for (menu.bar, 0..) |b_menu, b_at| {
                for (b_menu.items, 0..) |b, b_item| {
                    if (a_at == b_at and a_item == b_item) continue;
                    const b_key = b.shortcut orelse continue;
                    try std.testing.expect(a_key.key != b_key.key or a_key.shift != b_key.shift);
                }
            }
        }
    }
}

test "shortcut text uses Cmd on macOS and Ctrl elsewhere" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("Cmd+O", try menu.text(.{ .key = 'O' }, .macos, &buf));
    try std.testing.expectEqualStrings("Ctrl+O", try menu.text(.{ .key = 'O' }, .windows, &buf));
    try std.testing.expectEqualStrings("Ctrl+Shift+R", try menu.text(.{ .key = 'R', .shift = true }, .linux, &buf));
}

test "a buffer too small for the text is an error" {
    var buf: [3]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, menu.text(.{ .key = 'O' }, .linux, &buf));
}

test "Quit leaves File on macOS only" {
    const quit = menu.file[2];
    try std.testing.expect(!menu.shows(quit, .macos));
    try std.testing.expect(menu.shows(quit, .windows));
    try std.testing.expect(menu.shows(quit, .linux));
    try std.testing.expect(menu.shows(menu.file[0], .macos));
}

test "find maps a key and shift to its action in any case" {
    const bar: []const menu.Menu = &menu.bar;
    try std.testing.expect(menu.find(bar, 'o', false).?.eql(.{ .command = .open_elf }));
    try std.testing.expect(menu.find(bar, 'R', false).?.eql(.{ .command = .run }));
    try std.testing.expect(menu.find(bar, 'r', true).?.eql(.{ .command = .reset }));
    try std.testing.expect(menu.find(bar, '3', false).?.eql(.{ .toggle = .camera }));
    try std.testing.expectEqual(@as(?menu.Action, null), menu.find(bar, 'Z', false));
    try std.testing.expectEqual(@as(?menu.Action, null), menu.find(bar, 'O', true));
}

test "nothing loaded: only Open, Quit and the view toggles fire" {
    const idle = menu.State{};
    try std.testing.expect(menu.enabled(.{ .command = .open_elf }, idle));
    try std.testing.expect(menu.enabled(.{ .command = .quit }, idle));
    try std.testing.expect(menu.enabled(.{ .toggle = .memory }, idle));
    inline for (.{ .close, .run, .pause, .step, .reset }) |command| {
        try std.testing.expect(!menu.enabled(.{ .command = command }, idle));
    }
}

test "loaded and halted: run and step fire, pause does not" {
    const halted = menu.State{ .loaded = true };
    try std.testing.expect(menu.enabled(.{ .command = .run }, halted));
    try std.testing.expect(menu.enabled(.{ .command = .step }, halted));
    try std.testing.expect(menu.enabled(.{ .command = .reset }, halted));
    try std.testing.expect(menu.enabled(.{ .command = .close }, halted));
    try std.testing.expect(!menu.enabled(.{ .command = .pause }, halted));
}

test "running: pause fires, run and step do not" {
    const running = menu.State{ .loaded = true, .running = true };
    try std.testing.expect(menu.enabled(.{ .command = .pause }, running));
    try std.testing.expect(menu.enabled(.{ .command = .reset }, running));
    try std.testing.expect(!menu.enabled(.{ .command = .run }, running));
    try std.testing.expect(!menu.enabled(.{ .command = .step }, running));
}

test "eql tells commands and toggles apart" {
    const run: menu.Action = .{ .command = .run };
    try std.testing.expect(run.eql(.{ .command = .run }));
    try std.testing.expect(!run.eql(.{ .command = .pause }));
    try std.testing.expect(!run.eql(.{ .toggle = .board }));
}
