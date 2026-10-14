//! Host tests for the time bar's speed field (RA8EMU-808): what it accepts
//! and refuses, how it reads, and speeds applied to a spawned `serve
//! --stdio` session over the link.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const proto = ra8.rpc.session.rpc;
const session_link = gui_app.session_link;
const speed_field = gui_app.speed_field;
const Link = session_link.Link;
const Field = speed_field.Field;
const Env = proto.Client.Env;

const elf_path = "tests/fixtures/fpu/fp_basic.elf";

test "the field takes the range --speed takes, and max" {
    try std.testing.expectEqual(@as(?u64, 250), speed_field.parse("0.25"));
    try std.testing.expectEqual(@as(?u64, 5000), speed_field.parse("5"));
    try std.testing.expectEqual(@as(?u64, 100_000), speed_field.parse("100"));
    try std.testing.expectEqual(@as(?u64, 1), speed_field.parse("0.001"));
    try std.testing.expectEqual(@as(?u64, 0), speed_field.parse("max"));
    try std.testing.expectEqual(@as(?u64, 0), speed_field.parse("MAX"));
    try std.testing.expectEqual(@as(?u64, 2000), speed_field.parse("2x"));
    try std.testing.expectEqual(@as(?u64, 500), speed_field.parse("0.5x"));
    try std.testing.expectEqual(@as(?u64, 10_000), speed_field.parse("10X"));
    try std.testing.expectEqual(@as(?u64, 1000), speed_field.parse("  1x  "));
    for ([_][]const u8{ "0", "-1", "1e9", "abc", "0.0004", "1.2.3", "", "inf", "nan" }) |bad| {
        try std.testing.expectEqual(@as(?u64, null), speed_field.parse(bad));
    }
}

test "common speed presets match the expected values" {
    try std.testing.expectEqual(@as(usize, 8), speed_field.presets.len);
    try std.testing.expectEqualStrings("0.1x", speed_field.presets[0].label);
    try std.testing.expectEqual(@as(u64, 100), speed_field.presets[0].milli);
    try std.testing.expectEqualStrings("0.25x", speed_field.presets[1].label);
    try std.testing.expectEqual(@as(u64, 250), speed_field.presets[1].milli);
    try std.testing.expectEqualStrings("0.5x", speed_field.presets[2].label);
    try std.testing.expectEqual(@as(u64, 500), speed_field.presets[2].milli);
    try std.testing.expectEqualStrings("1x", speed_field.presets[3].label);
    try std.testing.expectEqual(@as(u64, 1000), speed_field.presets[3].milli);
    try std.testing.expectEqualStrings("2x", speed_field.presets[4].label);
    try std.testing.expectEqual(@as(u64, 2000), speed_field.presets[4].milli);
    try std.testing.expectEqualStrings("5x", speed_field.presets[5].label);
    try std.testing.expectEqual(@as(u64, 5000), speed_field.presets[5].milli);
    try std.testing.expectEqualStrings("10x", speed_field.presets[6].label);
    try std.testing.expectEqual(@as(u64, 10_000), speed_field.presets[6].milli);
    try std.testing.expectEqualStrings("max", speed_field.presets[7].label);
    try std.testing.expectEqual(@as(u64, 0), speed_field.presets[7].milli);
}

test "the field keeps digits, one dot and max, and reads the speed in use" {
    var buf: [32]u8 = undefined;
    var field: Field = .{};
    try std.testing.expectEqualStrings("1x", try field.shown(&buf));
    field.typed("-0.2.5e");
    try std.testing.expectEqualStrings("0.25", field.text());
    field.len = 0;
    field.typed("MaX");
    try std.testing.expectEqualStrings("max", field.text());
    try std.testing.expectEqualStrings("0.25x", try speed_field.format(250, &buf));
    try std.testing.expectEqualStrings("0.001x", try speed_field.format(1, &buf));
    try std.testing.expectEqualStrings("12.5x", try speed_field.format(12_500, &buf));
    try std.testing.expectEqualStrings("max", try speed_field.format(0, &buf));
}

test "field startEditing, fresh backspace and typing replacement" {
    var buf: [32]u8 = undefined;
    var field: Field = .{};
    try std.testing.expectEqualStrings("1x", try field.shown(&buf));

    field.startEditing();
    try std.testing.expect(field.editing);
    try std.testing.expect(field.fresh);
    try std.testing.expectEqualStrings("1x", try field.shown(&buf));

    var link: Link = undefined;
    try std.testing.expectEqual(speed_field.Outcome.typing, try field.key(&link, speed_field.codes.backspace));
    try std.testing.expect(!field.fresh);
    try std.testing.expectEqual(@as(usize, 0), field.len);
    try std.testing.expectEqualStrings("", try field.shown(&buf));

    field.typed("5");
    try std.testing.expectEqualStrings("5", try field.shown(&buf));
    field.typed("x");
    try std.testing.expectEqualStrings("5x", try field.shown(&buf));

    try std.testing.expectEqual(speed_field.Outcome.typing, try field.key(&link, speed_field.codes.backspace));
    try std.testing.expectEqualStrings("5", try field.shown(&buf));

    try std.testing.expectEqual(speed_field.Outcome.cancel, try field.key(&link, speed_field.codes.escape));
    try std.testing.expect(!field.editing);
    try std.testing.expectEqualStrings("1x", try field.shown(&buf));

    field.startEditing();
    field.typed("2");
    try std.testing.expect(!field.fresh);
    try std.testing.expectEqualStrings("2", try field.shown(&buf));
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

/// Pump the link into the field until the session answers, for ten seconds.
fn settle(link: *Link, field: *Field) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (field.ask_id != null) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        if (link.pump()) |arrival| field.observe(arrival) else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn enter(link: *Link, field: *Field, text: []const u8) !speed_field.Outcome {
    field.typed(text);
    const outcome = try field.key(link, speed_field.codes.enter);
    try settle(link, field);
    return outcome;
}

test "speeds typed into the field reach a local session, and bad ones never leave it" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);

    var buf: [32]u8 = undefined;
    var field: Field = .{};
    try std.testing.expectEqual(speed_field.Outcome.sent, try enter(&link, &field, "0.25"));
    try std.testing.expectEqual(@as(u64, 250), field.applied);
    try std.testing.expectEqualStrings("0.25x", try field.shown(&buf));
    try std.testing.expectEqual(speed_field.Outcome.sent, try enter(&link, &field, "max"));
    try std.testing.expectEqualStrings("max", try field.shown(&buf));
    try std.testing.expectEqual(@as(?speed_field.Refusal, null), field.refused);

    try std.testing.expectEqual(speed_field.Outcome.refused, try enter(&link, &field, "0"));
    try std.testing.expectEqual(@as(?u32, null), field.ask_id);
    try std.testing.expectEqual(@as(?speed_field.Refusal, .invalid), field.refused);
    try std.testing.expectEqualStrings("0", try field.shown(&buf));
    try std.testing.expectEqual(speed_field.Outcome.cancel, try field.key(&link, speed_field.codes.escape));
    try std.testing.expectEqualStrings("max", try field.shown(&buf));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}

test "speed preset chosen from dropdown reaches a local session" {
    const gpa = std.testing.allocator;
    var local: session_link.Local = undefined;
    try local.spawn(std.testing.io, test_paths.emulator, elf_path);
    errdefer local.child.kill(std.testing.io);
    const rx = try gpa.alloc(u8, 2 * Env.max_frame);
    defer gpa.free(rx);
    const tx = try gpa.alloc(u8, Env.max_frame);
    defer gpa.free(tx);
    var link: Link = undefined;
    link.open(local.transport(), rx, tx);
    try connect(&link);

    var buf: [32]u8 = undefined;
    var field: Field = .{};
    try std.testing.expectEqual(speed_field.Outcome.sent, try field.choose(&link, 2000));
    try settle(&link, &field);
    try std.testing.expectEqual(@as(u64, 2000), field.applied);
    try std.testing.expectEqualStrings("2x", try field.shown(&buf));

    try std.testing.expectEqual(speed_field.Outcome.sent, try field.choose(&link, 0));
    try settle(&link, &field);
    try std.testing.expectEqual(@as(u64, 0), field.applied);
    try std.testing.expectEqualStrings("max", try field.shown(&buf));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}

/// What the session says to request `id`, with `field` still waiting on it.
fn answer(field: *Field, id: u32, refused: bool) void {
    const result: Env.Result = if (refused) .{ .err = @fromBackingInt(@intCast(0x0100)) } else .{ .ok = &.{} };
    field.observe(.{ .response = .{ .id = id, .result = result } });
}

test "an answer to an older speed leaves a newer edit and its fresh text alone" {
    var buf: [32]u8 = undefined;
    var field: Field = .{};
    field.ask_id = 7;
    field.asked = 5000;
    field.startEditing();
    answer(&field, 7, false);
    try std.testing.expectEqual(@as(u64, 5000), field.applied);
    try std.testing.expect(field.editing and field.fresh);
    try std.testing.expectEqualStrings("5x", try field.shown(&buf));
    field.typed("3");
    try std.testing.expectEqualStrings("3", try field.shown(&buf));

    // Typed text survives the answer, and the edit is still the field's.
    field.ask_id = 8;
    field.asked = 2000;
    answer(&field, 8, false);
    try std.testing.expectEqual(@as(u64, 2000), field.applied);
    try std.testing.expect(field.editing and !field.fresh);
    try std.testing.expectEqualStrings("3", field.text());
}

test "a refusal of an older speed does not mark a newer edit refused, and one with no edit does" {
    var field: Field = .{};
    field.ask_id = 4;
    field.asked = 5000;
    field.startEditing();
    field.typed("9");
    answer(&field, 4, true);
    try std.testing.expectEqual(@as(u64, 1000), field.applied);
    try std.testing.expectEqual(@as(?speed_field.Refusal, null), field.refused);
    try std.testing.expect(field.editing);
    try std.testing.expectEqualStrings("9", field.text());

    field.cancel();
    field.ask_id = 5;
    answer(&field, 5, true);
    try std.testing.expectEqual(@as(?speed_field.Refusal, .session), field.refused);
    try std.testing.expectEqual(@as(u64, 1000), field.applied);
}

test "an answer with no newer edit clears the sent text, and a stray answer changes nothing" {
    var buf: [32]u8 = undefined;
    var field: Field = .{};
    field.typed("2");
    field.ask_id = 3;
    field.asked = 2000;
    answer(&field, 99, false);
    try std.testing.expectEqual(@as(u64, 1000), field.applied);
    answer(&field, 3, false);
    try std.testing.expectEqualStrings("2x", try field.shown(&buf));
    try std.testing.expectEqual(@as(usize, 0), field.len);
}
