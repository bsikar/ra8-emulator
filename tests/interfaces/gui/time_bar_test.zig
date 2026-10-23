//! Host tests for the time bar (RA8EMU-807): where each control sits, what a
//! click lands on, a pinned CPU-backend golden frame, a narrow bar that never
//! paints past its area, the clock readout on the row its neighbours stand
//! on, kept to whole segments when the bar is narrow (RA8EMU-941), and clicks on step, run and
//! pause: a step goes to a spawned `serve --stdio` child, and run and pause
//! light and unlight the shell's sliced run (shell_run_test.zig runs the
//! slices).
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const light = &@import("gui_app").colors.palettes.light;
const Theme = @import("gui_app").colors.Theme;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const test_paths = @import("test_paths");
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;
const status_bar = gui_app.status.bar;
const speed_field = gui_app.speed_field;
const seek_field = gui_app.seek_field;
const time_readout = gui_app.time.readout;
const session_link = gui_app.session_link;
const bar = gui_app.time_bar;
const capture = gui_app.time.bar_capture;
const Run = gui_app.shell.run.Run;
const proto = ra8.rpc.session.rpc;
const Link = session_link.Link;
const Status = status_bar.Status;
const Rect = draw_list.Rect;

const Env = proto.Client.Env;
const elf_path = "tests/fixtures/fpu/fp_basic.elf";

const Models = struct {
    status: Status = .{},
    field: speed_field.Field = .{},
    seek: seek_field.Field = .{},
    readout: time_readout.Readout = .{},
    texts: capture.Texts = .{},
    run: Run = .{},

    fn sample() Models {
        var models: Models = .{};
        models.status.run = .{ .halted = .{ .address = 0x0800_0100, .reason = .stepped } };
        models.field.applied = 250;
        models.readout.virtual_ns = 83_456_000_000;
        models.readout.achieved_milli = 120;
        return models;
    }

    fn view(self: *Models, editing: bool) bar.View {
        return capture.view(&self.texts, &self.status, &self.field, &self.seek, &self.readout, &self.run, editing, false, false);
    }
};

fn middle(area: Rect) [2]i32 {
    return .{ area.x + @divTrunc(area.w, 2), area.y + @divTrunc(area.h, 2) };
}

test "the controls sit left to right and the clock takes what is left" {
    const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = bar.height };
    const layout = bar.Layout.of(area);
    try std.testing.expectEqual(@as(i32, bar.pad), layout.run.x);
    try std.testing.expectEqual(layout.run.x + layout.run.w + bar.gap, layout.pause.x);
    try std.testing.expectEqual(layout.pause.x + layout.pause.w + bar.gap, layout.step.x);
    try std.testing.expectEqual(layout.step.x + layout.step.w + bar.gap, layout.over.x);
    try std.testing.expectEqual(layout.over.x + layout.over.w + bar.gap, layout.out.x);
    try std.testing.expectEqual(layout.out.x + layout.out.w + bar.gap, layout.field.x);
    try std.testing.expectEqual(@as(i32, @intCast(font.textWidth(bar.field_chars))) + 2 * bar.pad + bar.drop_w, layout.field.w);
    try std.testing.expectEqual(area.w - bar.pad, layout.clock.x + layout.clock.w);
    try std.testing.expectEqual(@as(i32, bar.control_h), layout.run.h);
}

test "a click lands on the control under it, and nothing in the gaps or the clock" {
    const area: Rect = .{ .x = 20, .y = 100, .w = 480, .h = bar.height };
    const layout = bar.Layout.of(area);
    for ([_]bar.Control{ .run, .pause, .step, .over, .out, .field, .drop }) |control| {
        const at = middle(layout.rect(control));
        try std.testing.expectEqual(@as(?bar.Control, control), bar.hit(area, at[0], at[1]));
    }
    try std.testing.expectEqual(@as(?bar.Control, null), bar.hit(area, layout.run.x + layout.run.w, layout.run.y + 2));
    const clock = middle(layout.clock);
    try std.testing.expectEqual(@as(?bar.Control, null), bar.hit(area, clock[0], clock[1]));
    try std.testing.expectEqual(@as(?bar.Control, null), bar.hit(area, layout.run.x + 1, area.y));
}

fn pending(status: *const Status) bool {
    return status.load_id != null or status.pc_id != null or status.run == .running;
}

/// Pump the link into the status until nothing is outstanding, for ten seconds.
fn settle(link: *Link, status: *Status) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (pending(status)) {
        if (std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() > deadline) return error.Timeout;
        if (link.state != .connected) return error.LinkLost;
        if (link.pump()) |arrival| status.observe(link, arrival) else try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
}

fn connect(link: *Link) !void {
    const deadline = std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() + 10_000;
    while (link.state == .connecting and std.Io.Timestamp.now(std.testing.io, .awake).toMilliseconds() < deadline) {
        _ = link.pump();
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(link.state == .connected);
}

/// Click the middle of `control` in `area` and press what the hit test found.
fn click(area: Rect, control: bar.Control, status: *Status, run: *Run, link: *Link) !void {
    const at = middle(bar.Layout.of(area).rect(control));
    const found = bar.hit(area, at[0], at[1]) orelse return error.Missed;
    try std.testing.expectEqual(control, found);
    try capture.press(found, status, run, link);
}

test "a click on step drives a served session, and run and pause light and unlight the sliced run" {
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

    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    var status: Status = .{};
    try status.load(&link, elf_path, bytes);
    try settle(&link, &status);
    const reset_pc = status.run.halted.address;
    const area: Rect = .{ .x = 0, .y = 0, .w = 480, .h = bar.height };

    var run: Run = .{};

    try click(area, .step, &status, &run, &link);
    try settle(&link, &status);
    try std.testing.expectEqual(@as(?proto.StopReason, .stepped), status.run.halted.reason);
    const stepped_to = status.run.halted.address;
    try std.testing.expect(stepped_to != reset_pc);

    // Run sends nothing: it lights the run, and the shell's frames pay it.
    try click(area, .run, &status, &run, &link);
    try std.testing.expectEqual(status_bar.Run.running, status.run);
    try std.testing.expect(run.lit);
    try std.testing.expectEqual(@as(?u32, null), status.run_id);
    try std.testing.expectEqual(stepped_to, run.address);

    // A step while it runs is not sent either.
    try click(area, .step, &status, &run, &link);
    try std.testing.expectEqual(@as(?u32, null), status.run_id);

    try click(area, .pause, &status, &run, &link);
    try std.testing.expect(!run.lit);
    status.haltedAt(run.halted() orelse return error.NoHalt);
    try std.testing.expectEqual(stepped_to, status.run.halted.address);

    try click(area, .field, &status, &run, &link);
    try std.testing.expect(!pending(&status));

    local.end();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try local.reap());
}

test "control boundaries have only whole buttons and never actionable slivers" {
    const controls = [_]bar.Control{ .run, .pause, .step, .over, .out, .field };
    var edge: i32 = bar.pad;
    for (controls) |control| {
        edge += bar.width(control);
        for ([_]i32{ -1, 0, 1 }) |delta| {
            const reserve = if (control == .field) bar.gap + bar.clock_min else 0;
            const area: Rect = .{ .x = 23, .y = 17, .w = edge + bar.pad + reserve + delta, .h = bar.height };
            const rect = bar.Layout.of(area).rect(control);
            if (delta < 0) {
                try std.testing.expect(rect.empty());
            } else {
                try std.testing.expectEqual(bar.width(control), rect.w);
                try std.testing.expectEqual(@as(i32, bar.control_h), rect.h);
                const point = middle(rect);
                try std.testing.expectEqual(@as(?bar.Control, control), bar.hit(area, point[0], point[1]));
            }
        }
        edge += bar.gap;
    }
    for ([_]Rect{ .{ .x = 23, .y = 17, .w = 0, .h = bar.height }, .{ .x = 23, .y = 17, .w = 480, .h = 0 }, .{ .x = 23, .y = 17, .w = 480, .h = bar.control_h - 1 } }) |area| {
        for (controls) |control| try std.testing.expect(bar.Layout.of(area).rect(control).empty());
        try std.testing.expectEqual(@as(?bar.Control, null), bar.hit(area, 27, 18));
    }
}

test "time bar: a turbo run notes Advancing" {
    var models = Models.sample();
    models.run.turbo_out = true;
    try std.testing.expectEqualStrings("Advancing", models.view(false).note.?);
}

test "time bar: the turbo note carries the estimate" {
    var models = Models.sample();
    models.run.turbo_out = true;
    models.run.turbo_eta = 1_500_000_000;
    try std.testing.expectEqualStrings("Advancing, ~2s left", models.view(false).note.?);
}
