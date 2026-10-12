//! Host tests for the shell's board pick (RA8EMU-1152): the composed
//! profile follows the chosen panel, and a choice saves and applies.
const std = @import("std");
const gui = @import("gui_app");
const board_pick = gui.shell.board_pick;

test "compose keeps the board's own panel when none is named" {
    const out = board_pick.compose(std.testing.allocator, "") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "panel=ek_ra8d2") != null);
}

test "compose rewrites the panel line to the chosen stem" {
    const out = board_pick.compose(std.testing.allocator, "sample_eink") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "panel=sample_eink") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "panel=ek_ra8d2") == null);
}

test "compose drops the panel line when the choice names none" {
    const out = board_pick.compose(std.testing.allocator, "none") orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "panel=") == null);
}

test "a panel choice saves and hands the composed profile to apply" {
    const Recorder = struct {
        profile: [512]u8 = undefined,
        len: usize = 0,

        fn apply(context: *anyopaque, profile: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memcpy(self.profile[0..profile.len], profile);
            self.len = profile.len;
        }
    };
    var recorder = Recorder{};
    var pick: board_pick.Pick = .{ .allocator = std.testing.allocator };
    pick.context = &recorder;
    pick.applyFn = Recorder.apply;
    pick.choose(.{ .kind = .panel, .stem = "sample_eink" });
    try std.testing.expectEqualStrings("sample_eink", pick.chosen.panel());
    try std.testing.expect(std.mem.indexOf(u8, recorder.profile[0..recorder.len], "panel=sample_eink") != null);
    if (pick.composed) |text| std.testing.allocator.free(text);
}

test "a menu choice that rebuilds the session marks the reload" {
    const Recorder = struct {
        fn apply(context: *anyopaque, profile: []const u8) anyerror!void {
            _ = profile;
            _ = context;
        }
    };
    var recorder = Recorder{};
    var pick: board_pick.Pick = .{ .allocator = std.testing.allocator };
    pick.context = &recorder;
    pick.applyFn = Recorder.apply;
    pick.choose(.{ .kind = .panel, .stem = "sample_480x272" });
    try std.testing.expect(pick.reload);
    if (pick.composed) |text| std.testing.allocator.free(text);
}

test "a profile file the OS picker sent applies its own text" {
    const dir = "board_pick_picked_scratch";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    const path = dir ++ "/custom.board";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = "version=1\npanel=none\n" });
    const Recorder = struct {
        profile: [256]u8 = undefined,
        len: usize = 0,

        fn apply(context: *anyopaque, profile: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            @memcpy(self.profile[0..profile.len], profile);
            self.len = profile.len;
        }
    };
    var recorder = Recorder{};
    var pick: board_pick.Pick = .{ .allocator = std.testing.allocator, .io = std.testing.io };
    pick.context = &recorder;
    pick.applyFn = Recorder.apply;
    pick.picked(path);
    try std.testing.expectEqualStrings("version=1\npanel=none\n", recorder.profile[0..recorder.len]);
    try std.testing.expect(pick.reload);
    if (pick.composed) |text| std.testing.allocator.free(text);
}

test "a board choice resets the panel and composes the board's own" {
    var pick: board_pick.Pick = .{ .allocator = std.testing.allocator };
    pick.choose(.{ .kind = .panel, .stem = "none" });
    pick.choose(.{ .kind = .board, .stem = "ek_ra8d2" });
    try std.testing.expectEqual(@as(usize, 0), pick.chosen.panel_len);
    const out = pick.composed orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, out, "panel=ek_ra8d2") != null);
    if (pick.composed) |text| std.testing.allocator.free(text);
}
