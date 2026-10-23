//! Host tests for the time bar's seek field (slice 19): typing keeps what
//! a target is made of, Enter hands the typed target to the session's
//! seek, and a send the link refuses keeps the text and the keyboard with
//! the refusal named in the status bar. The seek field and the speed
//! field never hold the keyboard at once.
const std = @import("std");
const gui_app = @import("gui_app");
const seek_field = gui_app.seek_field;
const time_bar = gui_app.time_bar;
const frame = gui_app.shell.frame;
const time_mod = gui_app.shell.time;
const status_bar = gui_app.status.bar;
const session_link = gui_app.session_link;

const Time = time_mod.Time;
const Status = status_bar.Status;
const Rect = frame.Rect;

/// Wide enough for every control, both fields and the clock's minimum.
const bar_area = Rect{ .x = 0, .y = 200, .w = 900, .h = time_bar.height };

fn layout() time_bar.Layout {
    return time_bar.Layout.of(frame.toList(bar_area));
}

test "seek field: typing keeps what a target is made of and drops the rest" {
    var f: seek_field.Field = .{};
    f.startEditing();
    f.typed("12.402s+500ms\x01\x7f");
    try std.testing.expectEqualStrings("12.402s+500ms", f.text());
}

test "seek field: the field caps at its longest target" {
    var f: seek_field.Field = .{};
    f.startEditing();
    f.typed("arrival 2 0x08001abcXYZ");
    try std.testing.expectEqual(seek_field.max_chars, f.text().len);
}

test "seek field: Enter on an empty field cancels" {
    var f: seek_field.Field = .{};
    f.startEditing();
    var time: Time = .{};
    var status: Status = .{};
    var link = session_link.Link{};
    const outcome = try f.key(&status, &time.run, &link, seek_field.codes.enter);
    try std.testing.expectEqual(seek_field.Outcome.cancel, outcome);
    try std.testing.expect(!f.editing);
}

test "seek field: a send the link refuses keeps the text and the keyboard" {
    var f: seek_field.Field = .{};
    f.startEditing();
    f.typed("+500ms");
    var time: Time = .{};
    var status: Status = .{};
    var link = session_link.Link{};
    if (f.key(&status, &time.run, &link, seek_field.codes.enter)) |_| {
        return error.TestUnexpectedResult;
    } else |_| {}
    try std.testing.expectEqualStrings("+500ms", f.text());
    try std.testing.expect(f.editing);
    try std.testing.expect(status.refused == null);
}

test "seek field: Escape drops the text and Backspace drops a character" {
    var f: seek_field.Field = .{};
    var time: Time = .{};
    var status: Status = .{};
    var link = session_link.Link{};
    f.startEditing();
    f.typed("25%");
    const outcome = try f.key(&status, &time.run, &link, seek_field.codes.escape);
    try std.testing.expectEqual(seek_field.Outcome.cancel, outcome);
    try std.testing.expectEqualStrings("", f.text());
    f.startEditing();
    f.typed("frame 12");
    _ = try f.key(&status, &time.run, &link, seek_field.codes.backspace);
    try std.testing.expectEqualStrings("frame 1", f.text());
}

test "the bar's seek field takes the keyboard and hands a target on" {
    var time: Time = .{};
    var status: Status = .{};
    var link = session_link.Link{};
    const box = layout().seek;
    try std.testing.expect(!box.empty());
    try std.testing.expect(time.press(bar_area, box.x + 1, box.y + 1, &status, &link));
    try std.testing.expect(time.seek_editing);
    try std.testing.expect(!time.editing);
    try std.testing.expect(time.handle(.{ .text = .of("12.402s") }, &link, &status));
    try std.testing.expectEqualStrings("12.402s", time.seek.text());
    // Enter on an unconnected link: the refusal surfaces in the status bar
    // and the typed target stays for a fix.
    try std.testing.expect(time.handle(.{ .key = .{ .code = seek_field.codes.enter, .down = true } }, &link, &status));
    try std.testing.expectEqual(status_bar.Refusal.seek, status.refused.?);
    try std.testing.expect(time.seek_editing);
    try std.testing.expectEqualStrings("12.402s", time.seek.text());
    // Escape lets the keyboard go and drops the text.
    try std.testing.expect(time.handle(.{ .key = .{ .code = seek_field.codes.escape, .down = true } }, &link, &status));
    try std.testing.expect(!time.seek_editing);
    try std.testing.expectEqualStrings("", time.seek.text());
    // The speed field's click takes the keyboard back.
    const boxes = layout();
    try std.testing.expect(!boxes.field.empty());
    try std.testing.expect(time.press(bar_area, boxes.field.x + 1, boxes.field.y + 1, &status, &link));
    try std.testing.expect(time.editing);
    try std.testing.expect(!time.seek_editing);
}

test "the seek field sits right of the speed field and drops first on a narrow bar" {
    const wide = layout();
    try std.testing.expect(!wide.seek.empty());
    try std.testing.expect(wide.seek.x >= wide.field.x + wide.field.w);
    const narrow = time_bar.Layout.of(frame.toList(.{ .x = 0, .y = 200, .w = 430, .h = time_bar.height }));
    if (!narrow.field.empty()) try std.testing.expect(narrow.seek.empty());
    try std.testing.expectEqual(time_bar.seek_chars, seek_field.max_chars);
}
