// Tests for src/interfaces/gui/video/capture.zig: the decorator passes
// every window call through, a frame the window draws itself counts as a
// frame for the script, and a recording rasterizes every frame instead.
const std = @import("std");
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const stub_window = @import("../stub_window.zig");

const Capture = gui_app.video.capture.Capture;
const draw_list = ra8.render.draw_list;

test "every window call reaches the window behind the capture" {
    var stub: stub_window.Stub = .{};
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    try stub_window.expectPassesThrough(cap.platform(), &stub);
}

test "a frame the window draws itself counts, and the script polls again after it" {
    var stub: stub_window.Stub = .{};
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    const shown = cap.platform();
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    _ = shown.poll();
    try std.testing.expect(cap.polled_this_frame);
    try std.testing.expect(try shown.show(&list, null));
    try std.testing.expectEqual(@as(u32, 1), stub.shows);
    try std.testing.expectEqual(@as(u32, 1), cap.frame_counter);
    try std.testing.expect(!cap.polled_this_frame);
}

test "a window that does not draw the list leaves the frame to present" {
    var stub: stub_window.Stub = .{ .draws = false };
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    try std.testing.expect(!try cap.platform().show(&list, null));
    try std.testing.expectEqual(@as(u32, 0), cap.frame_counter);
}

test "while recording, every frame is rasterized so it can be kept" {
    var stub: stub_window.Stub = .{};
    var cap = Capture.init(std.testing.allocator, stub.platform());
    defer cap.deinit();
    // Only whether a writer is set is read here.
    var writer: gui_app.video.writer.Writer = undefined;
    cap.writer = &writer;
    var list = draw_list.DrawList.init(std.testing.allocator, 4, 4);
    defer list.deinit();
    try std.testing.expect(!try cap.platform().show(&list, null));
    try std.testing.expectEqual(@as(u32, 0), stub.shows);
    try std.testing.expectEqual(@as(u32, 0), cap.frame_counter);
}
const Rig = @import("../local_rig.zig").Rig;
const Manual = @import("../manual_clock.zig").Manual;
const proto = ra8.rpc.session.rpc;
const Color = ra8.render.draw_list.Color;
const gpa = std.testing.allocator;
const image = "tests/fixtures/gpio/blink.elf";

fn luma(color: Color) u8 {
    const r: u32 = color.r;
    const g: u32 = color.g;
    const b: u32 = color.b;
    return @intCast(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
}

// It also covers the scripted recording route: painted clicks recorded
// to video without changing the live frame, and a scripted Pause that
// cancels a queue-pressured run through the capture platform.

test "scripted painted slice click records cursor video without changing the live frame and quits once" {
    var rig: Rig = undefined;
    try rig.open(image);
    defer rig.deinit();
    var shell = gui_app.shell.loop.Shell.init(gpa, try gui_app.pane_layout.Layout.init(gpa, .{ .kind = .timeline, .core = .cpu0 }));
    defer shell.deinit();
    shell.link = &rig.link;
    shell.themes.choose(.dark);
    const model = &shell.timeline.?;
    try model.take(.{ .when = 100, .core = 0, .kind = .switch_to, .thread = 0xA });
    try model.take(.{ .when = 700, .core = 0, .kind = .switch_to, .thread = 0xB });
    try model.finish(1000);
    var panes = gui_app.shell.panes.Panes{ .timeline = model };
    shell.painter = panes.painter();
    var head = gui_app.headless.Headless.init(gpa, 480, 320);
    defer head.deinit();
    try std.testing.expect(try shell.step(head.platform()));
    var solved = try gui_app.shell.frame.solve(&shell.layout, gpa, 480, 320);
    defer solved.deinit(gpa);
    const body = gui_app.shell.frame.bodyOf(solved.panes.items[0].area);
    const x = body.x + gui_app.timeline_pane.col_w + 260;
    const y = body.y + gui_app.timeline_pane.header_h + 2;
    const blue = gui_app.colors.palettes.dark.hue.blue;
    try std.testing.expectEqual(blue, head.last.?.at(@intCast(x), @intCast(y)));
    var text_buf: [96]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "at frame 0 click {d} {d}\n", .{ x, y });
    var parsed = try gui_app.script.parser.parse(gpa, text);
    defer parsed.deinit();
    var runner = gui_app.script.runner.Runner.init(gpa, parsed.items.items, true);
    defer runner.deinit();
    runner.cooldown_frames = 3;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_name_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    const path = try std.fmt.allocPrint(gpa, "{s}/shell.y4m", .{root});
    defer gpa.free(path);
    var writer = try gui_app.video.writer.Writer.init(gpa, std.testing.io, path, 30);
    defer writer.deinit();
    var cap = gui_app.video.capture.Capture.init(gpa, head.platform());
    defer cap.deinit();
    cap.runner = &runner;
    cap.writer = &writer;
    cap.show_cursor = true;
    cap.bind(&shell);
    defer cap.unbind();
    for (0..3) |_| try std.testing.expect(try shell.step(cap.platform()));
    try std.testing.expectEqual(@as(?u64, 100), shell.snaps.cursor.at_ns);
    try std.testing.expectEqual(@as(usize, 1), runner.ripples.items.len);
    try std.testing.expectEqual(blue, head.last.?.at(@intCast(x), @intCast(y)));
    const overlay = cap.overlay_frame.?.at(@intCast(x), @intCast(y));
    try std.testing.expect(!std.meta.eql(blue, overlay));
    try std.testing.expectEqual(@as(u32, 3), cap.frame_counter);
    try std.testing.expect(!try shell.step(cap.platform()));
    try std.testing.expectEqual(@as(u32, 3), cap.frame_counter);
    try writer.finish();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(1 << 20));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "YUV4MPEG2 W480 H320 F30:1"));
    const header = (std.mem.indexOfScalar(u8, bytes, '\n') orelse return error.NoHeader) + 1;
    const frame_bytes = 480 * 320 * 3 / 2;
    try std.testing.expectEqual(header + 2 * (6 + frame_bytes), bytes.len);
    try std.testing.expectEqualStrings("FRAME\n", bytes[header..][0..6]);
    try std.testing.expectEqualStrings("FRAME\n", bytes[header + 6 + frame_bytes ..][0..6]);
    try std.testing.expectEqual(luma(overlay), bytes[header + 6 + @as(usize, @intCast(y)) * 480 + @as(usize, @intCast(x))]);
    try std.testing.expect(luma(overlay) != luma(blue));
}

test "scripted Pause cancels a queue pressured Run through the capture platform" {
    var rig: Rig = undefined;
    try rig.open(image);
    defer rig.deinit();
    var shell = gui_app.shell.loop.Shell.init(gpa, try gui_app.pane_layout.twoCore(gpa));
    defer shell.deinit();
    try rig.load(&shell.status, image);
    var time: gui_app.shell.time.Time = .{};
    time.field.applied = 1;
    time.stale = false;
    time.run.start(shell.status.run.halted.address);
    shell.status.running();
    var manual: Manual = .{};
    shell.clock = manual.clock();
    shell.time = &time;
    shell.link = &rig.link;
    for (0..proto.pending_slots) |_| _ = try rig.link.send(proto.Now, .now, .{ .core = .cpu0 });
    var parsed = try gui_app.script.parser.parse(gpa, "at frame 1 click bar:pause\n");
    defer parsed.deinit();
    var runner = gui_app.script.runner.Runner.init(gpa, parsed.items.items, false);
    defer runner.deinit();
    var head = gui_app.headless.Headless.init(gpa, 480, 320);
    defer head.deinit();
    var cap = gui_app.video.capture.Capture.init(gpa, head.platform());
    defer cap.deinit();
    cap.runner = &runner;
    cap.bind(&shell);
    defer cap.unbind();
    try std.testing.expect(try shell.step(cap.platform()));
    try std.testing.expect(time.run.lit and !time.run.refused);
    try std.testing.expect(shell.status.run == .running);
    try std.testing.expectEqual(@as(?u32, null), time.run.slice_id);
    try std.testing.expect(try shell.step(cap.platform()));
    try std.testing.expect(shell.status.run == .halted and !time.run.lit and !time.run.refused);
    try rig.session.answer();
    try std.testing.expect(try shell.step(cap.platform()));
    try std.testing.expect(shell.status.run == .halted and !time.run.lit);
    try std.testing.expectEqual(@as(?u32, null), time.run.slice_id);
    try std.testing.expectEqual(@as(?gui_app.status.bar.Refusal, null), shell.status.refused);
}
