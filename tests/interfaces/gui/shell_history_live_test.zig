//! The branch tree and the state diff through the real shell (row 23): a
//! headless window whose session records history and is served in-process,
//! driven by a GUI script through the capture decorator the way ra8_gui
//! runs `--gui-script`. The tree leaf lists the session's branches over the
//! link and a click on a node switches the session to that branch; the diff
//! leaf compares the cursor with one recorded stop and its step buttons move
//! the stop.
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const live_shell = @import("live_shell.zig");
const Live = live_shell.Live;

const transport = ra8.session.transport;
const seek_facts = ra8.session.history_seek_facts;
const pane_layout = gui_app.pane_layout;
const branch_tree = gui_app.branch_tree;
const diff_pane = gui_app.diff_pane;
const mib: u64 = 1024 * 1024;

const image = "tests/fixtures/dfu/dfu_bootloader.elf";

const FakeWall = struct {
    now_ns: u64 = 0,
    fn now(context: *anyopaque) u64 {
        const self: *FakeWall = @ptrCast(@alignCast(context));
        self.now_ns += 1_000_000;
        return self.now_ns;
    }
    fn wall(self: *FakeWall) transport.Wall {
        return .{ .context = self, .nowFn = now };
    }
};

/// Runs the image, backs the cursor up to its first checkpoint and writes
/// there: the write waits for the confirmation of its fork. With `confirm`
/// the session forks a second line and stands on it.
fn fork(live: *Live, confirm: bool) !void {
    const gpa = std.testing.allocator;
    const session = live.session.setup.owner.session();
    _ = try session.run(.cpu0, .run);
    const t = live.session.setup.owner.transport();
    const bridge = t.history.?;
    const facts = try seek_facts.gather(gpa, try bridge.logBytes.?(bridge.context));
    defer gpa.free(facts.checkpoints);
    try std.testing.expect(facts.checkpoints.len > 1);
    const at = facts.checkpoints[0].position;
    const text = try std.fmt.allocPrint(gpa, "{d}:{s}:{d}:{s}", .{ at.r, @tagName(at.phase), at.o, @tagName(at.gap) });
    defer gpa.free(text);
    var wall = FakeWall{};
    _ = try t.command(.{ .seek = .{ .target = text } });
    try std.testing.expect((try t.pump(wall.wall(), wall.now_ns + 4_000_000)).finished != null);
    try std.testing.expectError(error.ForkNeedsConfirmation, session.write(.cpu0, 0x2000_0000, "\x5A"));
    if (!confirm) return;
    try session.confirmFork();
    try std.testing.expectEqual(@as(u32, 1), session.fork_router.?.active_line);
}

fn prepare(live: *Live) anyerror!void {
    return fork(live, true);
}

fn prepareUnconfirmed(live: *Live) anyerror!void {
    return fork(live, false);
}

/// The window's panes: the branch tree on the left, the state diff right.
fn showHistoryPanes(live: *Live) !void {
    const gpa = std.testing.allocator;
    live.shell.layout.deinit();
    live.shell.layout = try pane_layout.Layout.init(gpa, .{ .kind = .branches, .core = .cpu0 });
    _ = try live.shell.layout.split(live.shell.layout.root, .across, .{ .kind = .diff, .core = .cpu0 });
}

fn body(live: *Live, kind: pane_layout.Kind) !ra8.render.draw_list.Rect {
    const gpa = std.testing.allocator;
    var solved = try gui_app.shell.frame.solve(&live.shell.layout, gpa, live_shell.width, live_shell.height);
    defer solved.deinit(gpa);
    for (solved.panes.items) |placed| {
        const pane = live.shell.layout.pane(placed.index) orelse continue;
        if (pane.kind == kind) return gui_app.shell.frame.bodyOf(placed.area);
    }
    return error.NoLeaf;
}

test "a script opens the branch tree, switches a branch and diffs the cursor against a stop" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var live: Live = undefined;
    try live.openWith(image, 1000, .{ .root = root, .checkpoint_every = 1, .ram_budget = 256 * mib }, prepare);
    defer live.deinit();
    const session = live.session.setup.owner.session();
    try showHistoryPanes(&live);

    var parsed = try gui_app.script.parser.parse(gpa,
        \\at frame 30 click tree:node0
        \\at frame 60 click diff:earlier
    );
    defer parsed.deinit();
    var runner = gui_app.script.runner.Runner.init(gpa, parsed.items.items, true);
    defer runner.deinit();
    var cap = gui_app.video.capture.Capture.init(gpa, live.window.platform());
    defer cap.deinit();
    cap.runner = &runner;
    cap.bind(&live.shell);
    defer cap.unbind();

    // The tree leaf lists both lines, the forked one live, and the diff
    // leaf compares the cursor with the newest stop.
    for (0..20) |_| try std.testing.expect(try live.shell.step(cap.platform()));
    const tree = &live.branches.state;
    try std.testing.expectEqual(@as(usize, 2), tree.items_len);
    try std.testing.expectEqual(@as(u32, 0), tree.items()[0].id);
    try std.testing.expect(!tree.items()[0].is_live);
    try std.testing.expectEqual(@as(u32, 1), tree.items()[1].id);
    try std.testing.expect(tree.items()[1].is_live);
    try std.testing.expectEqual(@as(u32, 0), tree.items()[1].parent);
    try std.testing.expect(live.diff.view.picked);
    try std.testing.expect(live.diff.frames > 0);
    const newest = live.diff.pick.?;
    try std.testing.expectEqual(live.diff.frames - 1, newest);

    // The filmstrip holds the navigation index's frames, laid out on the strip.
    const film = live.filmstrip.strip.items();
    try std.testing.expect(film.len >= 1);
    try std.testing.expect(film[0].has_frame and !film[0].rect.empty());

    // The tree painted its nodes: the live node carries its tag.
    const tree_body = try body(&live, .branches);
    const live_node = branch_tree.nodeRect(tree_body, 1);
    try std.testing.expectEqual(dark.well, live.pixel(live_node.x + 2, live_node.y + 2));

    // The script's click on the root node switches the session to line 0.
    for (0..30) |_| try std.testing.expect(try live.shell.step(cap.platform()));
    try std.testing.expectEqual(@as(u32, 0), session.fork_router.?.active_line);
    try std.testing.expect(tree.items()[0].is_live);
    try std.testing.expect(!tree.items()[1].is_live);
    try std.testing.expect(!tree.switch_refused);

    // Its click on the diff leaf's earlier button steps the compared stop.
    for (0..40) |_| try std.testing.expect(try live.shell.step(cap.platform()));
    try std.testing.expect(live.diff.view.picked);
    try std.testing.expect(live.diff.frames > 0);
    // The click moved the stop one earlier than the newest (or held at the oldest).
    try std.testing.expectEqual(live.diff.frames -| 2, live.diff.pick.?);
    var label_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&label_buf, "cursor ckpt r{d} vs ckpt {d} of {d} r{d}", .{ live.diff.view.pos_a.r, @as(u32, live.diff.pick.?) + 1, live.diff.frames, live.diff.view.pos_b.r });
    try std.testing.expectEqualStrings(want, live.diff.view.labelSlice());
    const diff_body = try body(&live, .diff);
    const earlier = diff_pane.buttonEarlier(diff_body);
    try std.testing.expectEqual(dark.button_face, live.pixel(earlier.x + 1, earlier.y + 1));
}

test "a write in the past raises the fork banner and its confirm button forks the line" {
    const gpa = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var live: Live = undefined;
    try live.openWith(image, 1000, .{ .root = root, .checkpoint_every = 1, .ram_budget = 256 * mib }, prepareUnconfirmed);
    defer live.deinit();
    const session = live.session.setup.owner.session();
    try showHistoryPanes(&live);

    var parsed = try gui_app.script.parser.parse(gpa, "at frame 20 click banner:confirm");
    defer parsed.deinit();
    var runner = gui_app.script.runner.Runner.init(gpa, parsed.items.items, true);
    defer runner.deinit();
    var cap = gui_app.video.capture.Capture.init(gpa, live.window.platform());
    defer cap.deinit();
    cap.runner = &runner;
    cap.bind(&live.shell);
    defer cap.unbind();

    // The tree leaf asks the session's fork status: the banner is up.
    for (0..15) |_| try std.testing.expect(try live.shell.step(cap.platform()));
    try std.testing.expect(live.branches.state.fork_pending);
    try std.testing.expectEqual(@as(u32, 0), session.fork_router.?.active_line);
    const banner = gui_app.shell.frame.bannerArea(live_shell.width, live_shell.height);
    try std.testing.expectEqual(dark.surface, live.pixel(banner.x + 2, banner.y + 2));

    // The script's click on Confirm forks the line and takes the banner down.
    for (0..30) |_| try std.testing.expect(try live.shell.step(cap.platform()));
    try std.testing.expectEqual(@as(u32, 1), session.fork_router.?.active_line);
    try std.testing.expect(!live.branches.state.fork_pending);
    try std.testing.expectEqual(@as(usize, 2), live.branches.state.items_len);
}
