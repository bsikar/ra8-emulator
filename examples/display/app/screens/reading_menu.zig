//! SPDX-License-Identifier: MIT
//! Copyright (c) 2026 Brighton Sikarskie
//!
//! R2 Reading menu: a preview of the page above the typography controls.

const tree = @import("../tree.zig");
const theme = @import("../theme.zig");
const screen = @import("../screen.zig");
const fields = @import("../fields.zig");
const prose = @import("../chrome/prose.zig");
const page = @import("../chrome/page.zig");
const typography = @import("../chrome/typography.zig");

const Builder = tree.Builder;
const Parts = tree.Parts;
const Widget = tree.Widget;
const Error = tree.Error;

const bar_height: i16 = 96;
const control_width: i16 = 148;
const preview_gap: i16 = 24;
const controls_gap: i16 = 12;
const controls_pad: i16 = 32;

const Group = struct {
    label: [:0]const u8,
    name: [:0]const u8,
    options: []const [:0]const u8,
    field: fields.Field,
    which: @import("../data/settings.zig").Choice,
};

const groups = [_]Group{
    .{ .label = "TEXT SIZE", .name = "menu.size", .options = &typography.sizes, .field = .reading_size, .which = .size },
    .{ .label = "TYPEFACE", .name = "menu.face", .options = &typography.faces, .field = .reading_face, .which = .face },
    .{ .label = "LINE SPACING", .name = "menu.spacing", .options = &typography.spacings, .field = .reading_spacing, .which = .spacing },
    .{ .label = "MARGINS", .name = "menu.margin", .options = &typography.margins, .field = .reading_margin, .which = .margin },
    .{ .label = "CLEAN REFRESH", .name = "menu.refresh", .options = &typography.refreshes, .field = .reading_refresh, .which = .refresh },
};

fn topBar(b: *Builder, title: [:0]const u8) Error!Widget {
    const library = try b.named("menu.library", try b.button("< Library", .reader_library, .plain));
    const done = try b.named("menu.done", try b.button("Done", .reader_done, .solid));
    const strip = try b.row(16, &.{
        tree.sized(library, 200),
        tree.grow(try b.label(title, theme.text.note.with(.center))),
        tree.sized(try b.button("Contents", .inert, .{}), 180),
        tree.sized(done, 140),
    });
    return tree.sized(strip, bar_height);
}

/// Children of the controls panel: a heading and a control per group, the
/// hairline and the now-playing row.
const control_parts: i16 = 2 * groups.len + 2;

fn controlsHeight() i16 {
    const rows = groups.len * (page.section_height + theme.metric.control) + theme.metric.hair + theme.metric.control;
    return @intCast(rows + (control_parts - 1) * controls_gap + 2 * controls_pad);
}

/// What is left for the page preview between the top bar and the controls.
fn previewHeight() i32 {
    return theme.panel.height - bar_height - theme.metric.rule - theme.metric.heavy_rule - controlsHeight();
}

fn preview(b: *Builder, ctx: screen.Ctx) Error!Widget {
    const reading = ctx.svc.library.reading();
    const style = typography.current(ctx.svc.settings);
    const text = ctx.svc.library.page(reading.page);
    const width = theme.panel.width - 2 * @as(i32, style.margin);
    const room = previewHeight() - 2 * @as(i32, style.margin) - style.heading_line - 2 * preview_gap;
    const lines: usize = @intCast(@max(1, @divTrunc(room, style.leading)));
    const sample = try prose.paragraph(b, text.paragraphs[0], style.body, width, style.leading, lines);
    return tree.grow(try b.padded(preview_gap, style.margin, &.{
        tree.sized(try b.label(reading.chapter_title, style.heading), style.heading_line),
        sample.widget,
        try page.filler(b),
    }));
}

fn controls(b: *Builder, ctx: screen.Ctx) Error!Widget {
    var parts: Parts = .{};
    for (groups) |group| {
        try parts.add(try page.section(b, group.label));
        const control = try b.named(group.name, try b.segmented(group.options, ctx.svc.settings.choice(group.which), group.field));
        try parts.add(tree.sized(control, theme.metric.control));
    }
    const track = ctx.svc.player.track();
    const playing = ctx.svc.player.playing();
    const line = try b.fmt("{s}  {s} - {s}", .{ if (playing) "Playing" else "Paused", track.album, track.artist });
    try parts.add(try page.hair(b));
    try parts.add(tree.sized(try b.row(16, &.{
        tree.grow(try b.label(line, theme.text.body.with(.right))),
        tree.sized(try b.named("menu.pause", try b.button(if (playing) "Pause" else "Play", .play_pause, .{})), control_width),
        tree.sized(try b.button("Skip", .skip, .{}), control_width),
    }), theme.metric.control));
    return tree.sized(try b.padded(controls_gap, controls_pad, parts.slice()), controlsHeight());
}

pub fn build(b: *Builder, ctx: screen.Ctx) Error!Widget {
    return b.col(0, &.{
        try topBar(b, ctx.svc.library.reading().title),
        tree.sized(try b.fill(theme.color.ink), theme.metric.rule),
        try preview(b, ctx),
        tree.sized(try b.fill(theme.color.ink), theme.metric.heavy_rule),
        try controls(b, ctx),
    });
}
