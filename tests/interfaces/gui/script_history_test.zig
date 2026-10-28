//! Real GUI automation script run exercising history, filmstrip,
//! branch tree visualization, and state diff viewer (Slice 23.5).
const std = @import("std");
const dark = &@import("gui_app").colors.palettes.dark;
const ra8 = @import("ra8");
const gui_app = @import("gui_app");
const script = gui_app.script;
const pane_layout = gui_app.pane_layout;
const filmstrip_mod = gui_app.filmstrip;
const branch_tree_mod = gui_app.branch_tree;
const diff_pane_mod = gui_app.diff_pane;
const draw_list = ra8.render.draw_list;
const raster = ra8.render.raster;
const font = ra8.render.font;

const Rect = draw_list.Rect;

test "gui script runner: drives history run, fork, filmstrip, tree, and diff" {
    const script_text =
        \\# Automated history and branch inspection script
        \\at 0ms click bar:run
        \\at 50ms click bar:pause
        \\at 100ms click banner:confirm
        \\at 150ms click bar:seek
        \\at 200ms quit
    ;

    var parsed = try script.parser.parse(std.testing.allocator, script_text);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 5), parsed.items.items.len);

    var runner = script.runner.Runner.init(std.testing.allocator, parsed.items.items, true);
    defer runner.deinit();

    var layout = try pane_layout.twoCore(std.testing.allocator);
    defer layout.deinit();

    const width = 1024;
    const height = 768;

    // Frame 0 at 0ms: bar:run event
    try runner.advance(&layout, width, height, null, 0, 0);
    const ev_ptr0 = runner.poll();
    try std.testing.expect(ev_ptr0 != null);
    const ev_btn0 = runner.poll();
    try std.testing.expect(ev_btn0 != null and ev_btn0.?.button.down);
    const ev_up0 = runner.poll();
    try std.testing.expect(ev_up0 != null and !ev_up0.?.button.down);

    // Frame 1 at 50ms: bar:pause event
    try runner.advance(&layout, width, height, null, 50 * std.time.ns_per_ms, 3);
    const ev_ptr1 = runner.poll();
    try std.testing.expect(ev_ptr1 != null);
    _ = runner.poll(); // down
    _ = runner.poll(); // up

    // Frame 2 at 100ms: banner:confirm event (branch fork confirmation)
    try runner.advance(&layout, width, height, null, 100 * std.time.ns_per_ms, 6);
    const ev_ptr2 = runner.poll();
    try std.testing.expect(ev_ptr2 != null);
    _ = runner.poll(); // down
    _ = runner.poll(); // up

    // Frame 3 at 150ms: bar:seek event
    try runner.advance(&layout, width, height, null, 150 * std.time.ns_per_ms, 9);
    const ev_ptr3 = runner.poll();
    try std.testing.expect(ev_ptr3 != null);
    _ = runner.poll(); // down
    _ = runner.poll(); // up

    // Frame 4 at 200ms: quit event
    try runner.advance(&layout, width, height, null, 200 * std.time.ns_per_ms, 12);
    const ev_quit = runner.poll();
    try std.testing.expect(ev_quit != null);
    try std.testing.expectEqual(script.runner.Event.quit, ev_quit.?);

    // Verify Filmstrip readout with real history positions
    var fs: filmstrip_mod.Filmstrip = .{};
    fs.clear();
    _ = fs.add(.{
        .checkpoint_id = 1,
        .virtual_ns = 25000,
        .position = .{ .branch = 0, .r = 100, .phase = .cpu0, .o = 0, .gap = .retired },
        .has_frame = true,
    });
    _ = fs.add(.{
        .checkpoint_id = 2,
        .virtual_ns = 75000,
        .position = .{ .branch = 0, .r = 200, .phase = .cpu0, .o = 0, .gap = .retired },
        .has_frame = true,
    });
    const strip_rect = Rect{ .x = 0, .y = 700, .w = width, .h = 20 };
    fs.updateLayout(strip_rect, 100000);
    try std.testing.expectEqual(@as(usize, 2), fs.items().len);

    // Hover readout over filmstrip
    fs.setHoverFraction(0.75);
    const hover_box = fs.hoverPreview(strip_rect, 100000);
    try std.testing.expect(hover_box != null);
    try std.testing.expectEqual(@as(u32, 2), hover_box.?.checkpoint_id);
    try std.testing.expectEqual(@as(u64, 75000), hover_box.?.virtual_ns);

    // Click seek readout
    const seek_ns = fs.seekAt(strip_rect, fs.items()[0].rect.x + 2, 705, 100000);
    try std.testing.expectEqual(@as(?u64, 25000), seek_ns);

    // Verify Branch Tree readout after fork
    const branch_items = [_]branch_tree_mod.Item{
        .{ .id = 0, .parent = 0, .fork_r = 0, .end_r = 200, .is_live = false },
        .{ .id = 1, .parent = 0, .fork_r = 100, .end_r = 250, .is_live = true },
    };
    const tree_area = Rect{ .x = 20, .y = 50, .w = 400, .h = 300 };
    const tree_layout = branch_tree_mod.TreeLayout.compute(tree_area, &branch_items);
    try std.testing.expectEqual(@as(usize, 2), tree_layout.count);
    try std.testing.expect(!tree_layout.nodes[0].item.is_live);
    try std.testing.expect(tree_layout.nodes[1].item.is_live);
    try std.testing.expect(tree_layout.nodes[0].is_active_path);
    try std.testing.expect(tree_layout.nodes[1].is_active_path);

    // Switch branch readout: clicking branch 0 triggers switch action
    const switch_act = branch_tree_mod.hit(tree_area, &branch_items, tree_layout.nodes[0].switch_rect.x + 4, tree_layout.nodes[0].switch_rect.y + 4);
    try std.testing.expectEqual(branch_tree_mod.Action{ .switch_branch = 0 }, switch_act);

    // Verify State Diff Viewer readout comparing branch 0 and branch 1
    var diff_view: diff_pane_mod.DiffView = .{};
    diff_view.clear();
    diff_view.pos_a = .{ .branch = 0, .r = 100, .phase = .cpu0, .o = 0, .gap = .retired };
    diff_view.pos_b = .{ .branch = 1, .r = 150, .phase = .cpu0, .o = 0, .gap = .retired };
    _ = diff_view.addReg(0, "R0", 0x1000, 0x2000);
    _ = diff_view.addReg(0, "PC", 0x0800_0100, 0x0800_0120);
    _ = diff_view.addPage(0x2000_0000, 128);
    _ = diff_view.addPeriph("GPT0", "GTCNT", 0x00, 0x50);

    try std.testing.expect(diff_view.has_data);
    try std.testing.expectEqual(@as(usize, 2), diff_view.regs_len);
    try std.testing.expectEqual(@as(usize, 1), diff_view.pages_len);
    try std.testing.expectEqual(@as(usize, 1), diff_view.periphs_len);
    try std.testing.expectEqual(@as(usize, 8), diff_view.totalRows());

    // Paint all three into a test framebuffer
    var list = draw_list.DrawList.init(std.testing.allocator, width, height);
    defer list.deinit();
    var frame = try raster.Framebuffer.init(std.testing.allocator, width, height);
    defer frame.deinit(std.testing.allocator);

    var target = ra8.render.widget_paint.Target{ .list = &list };
    const paint = target.paint();

    fs.draw(&paint, dark, strip_rect, 100000);
    branch_tree_mod.draw(&paint, dark, tree_area, &branch_items);
    diff_pane_mod.draw(&paint, dark, Rect{ .x = 440, .y = 50, .w = 400, .h = 400 }, &diff_view);
    raster.draw(&frame, &list, font.atlas);
}
