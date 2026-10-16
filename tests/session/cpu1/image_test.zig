//! The actual CPU1 ELF identity on a plain dual restore.
const std = @import("std");
const ra8 = @import("ra8");
const Harness = ra8.session.harness.Harness;
const Cpu1 = ra8.session.cpu1.bringup.Cpu1;
const Clock = ra8.session.run.loop.Clock;
const snapshot = ra8.session.zig.snapshot;
const source_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc.elf";
const second_path = "tests/fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf";
const source_bytes = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc.elf");
const second_bytes = @embedFile("../../fixtures/trustzone/cpu1_pingpong_ipc_cpu1.elf");

fn capture(h: *Harness) !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer out.deinit();
    try h.state.files.writeTo(&out.writer);
    return out;
}

fn fileAt(dir: std.Io.Dir, name: []const u8, bytes: []const u8) ![]u8 {
    var out = try dir.createFile(std.testing.io, name, .{});
    defer out.close(std.testing.io);
    try out.writeStreamingAll(std.testing.io, bytes);
    const root = try dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    return std.fs.path.join(std.testing.allocator, &.{ root, name });
}

test "plain dual wrong CPU1 ELF preserves guest provider and future continuation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source1: Cpu1 = .{};
    var source = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = source_path, .history_frames = 2 });
    defer source.deinit();
    try source1.open(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), &source, second_path);
    defer source1.close(std.testing.allocator);
    var saved = try capture(&source);
    defer saved.deinit();
    const path = try fileAt(tmp.dir, "source", saved.written());
    defer std.testing.allocator.free(path);
    var alternate = try std.testing.allocator.alloc(u8, second_bytes.len + 1);
    defer std.testing.allocator.free(alternate);
    @memcpy(alternate[0..second_bytes.len], second_bytes);
    alternate[second_bytes.len] = 0x42;
    _ = try ra8.board.image.elf.Image.init(alternate);
    const alt_path = try fileAt(tmp.dir, "alternate.elf", alternate);
    defer std.testing.allocator.free(alt_path);
    var wrong1: Cpu1 = .{};
    var wrong = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = source_path, .history_frames = 2 });
    defer wrong.deinit();
    try wrong1.open(std.testing.allocator, std.testing.io, std.Io.Dir.cwd(), &wrong, alt_path);
    defer wrong1.close(std.testing.allocator);
    var before = try capture(&wrong);
    defer before.deinit();
    var clock: Clock = .{ .io = std.testing.io, .memory = wrong.guest(), .board = wrong.board(), .timebase = &wrong.state.edge.timebase, .cpu1 = wrong.state.files.pair, .state = .{ .load = path }, .image_identity = snapshot.imageIdentity(source_bytes), .cpu1_image_identity = snapshot.imageIdentity(alternate) };
    defer clock.deinitSnapshot();
    const hook = snapshot.hook(&clock).?;
    try std.testing.expectError(error.ImageMismatch, hook.loadFn.?(hook.context, wrong.primaryCpu()));
    var after = try capture(&wrong);
    defer after.deinit();
    try std.testing.expectEqualSlices(u8, before.written(), after.written());
    try wrong.session().setRunBudget(.cpu0, 37);
    try std.testing.expectEqual(ra8.session.api.Ended.count, try wrong.session().run(.cpu0, .cont));
    var future = try capture(&wrong);
    defer future.deinit();
    try wrong.state.files.readFrom(before.written());
    try wrong.session().setRunBudget(.cpu0, 37);
    try std.testing.expectEqual(ra8.session.api.Ended.count, try wrong.session().run(.cpu0, .cont));
    var again = try capture(&wrong);
    defer again.deinit();
    try std.testing.expectEqualSlices(u8, future.written(), again.written());
}
