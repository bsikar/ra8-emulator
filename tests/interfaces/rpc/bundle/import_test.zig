const std = @import("std");

const fixture = @import("fixture.zig");
const ra8 = @import("ra8");
const rig = @import("../regression_rig.zig");

const bundle = ra8.snapshot.bundle;
const gpa = std.testing.allocator;
const importer = ra8.rpc.bundle_import;
const elf = fixture.elf;
const metadata = fixture.metadata;

test "snapshot bundle restores a separate session and leaves its source machine unchanged" {
    var original: ra8.rpc.served_setup.Served = undefined;
    try original.openInitial(gpa, std.testing.io, "", rig.small_profile, .{ .elf_bytes = elf }, null);
    defer original.deinit();
    try original.owner.session().setRunBudget(.cpu0, 100);
    _ = try original.owner.session().run(.cpu0, .run);
    const retired = original.owner.primaryCpu().retired;
    var state = std.Io.Writer.Allocating.init(gpa);
    defer state.deinit();
    try original.owner.state.files.writeTo(&state.writer);
    var state_reader = std.Io.Reader.fixed(state.written());
    var archive = std.Io.Writer.Allocating.init(gpa);
    defer archive.deinit();
    var writer = try bundle.writer.Writer.init(&archive.writer, metadata(), .{ .reader = &state_reader, .size = state.written().len }, null);
    try writer.finish();
    var input = std.Io.Reader.fixed(archive.written());
    const restored = try importer.open(gpa, std.testing.io, &input, .{ .elf0 = elf, .board_profile = rig.small_profile, .expected_board = "ek-ra8d2" });
    defer gpa.destroy(restored);
    defer restored.deinit();
    try std.testing.expectEqual(retired, restored.owner.primaryCpu().retired);
    try std.testing.expectEqual(retired, original.owner.primaryCpu().retired);
    try std.testing.expectEqualDeep(original.owner.primaryCpu().regs, restored.owner.primaryCpu().regs);
}

test "recording bundle restores state history and replay position into a new leased session" {
    var archive = try fixture.recording(false);
    defer archive.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    var input = std.Io.Reader.fixed(archive.bytes.written());
    const restored = try importer.open(gpa, std.testing.io, &input, .{ .history_root = path, .expected_board = "ek-ra8d2" });
    defer gpa.destroy(restored);
    defer restored.deinit();
    try std.testing.expectEqual(archive.retired, restored.owner.primaryCpu().retired);
    try std.testing.expectEqualDeep(archive.position, restored.owner.session().currentPosition());
    try std.testing.expect(restored.owner.session().fork_router != null);
    const facts = try ra8.rpc.history_bridge.Bridge.facts(&restored.bridge.?);
    try std.testing.expect(facts.checkpoints.len > 0);
    try std.testing.expectEqualDeep(archive.position, facts.current);
    const target = facts.checkpoints[0].position;
    const plane = restored.owner.transport();
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}:{d}:{s}:{d}:{s}", .{
        target.branch, target.r, @tagName(target.phase), target.o, @tagName(target.gap),
    });
    const ticket = try plane.command(.{ .seek = .{ .target = text } });
    var wall: Wall = .{};
    _ = try plane.finish(ticket, .{ .context = &wall, .nowFn = Wall.now }, null);
    try std.testing.expectEqualDeep(target, restored.owner.session().currentPosition());
}

test "a torn recording is rejected rather than repaired and leaves no imported session" {
    var archive = try fixture.recording(true);
    defer archive.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    var input = std.Io.Reader.fixed(archive.bytes.written());
    try std.testing.expectError(error.TruncatedLog, importer.open(gpa, std.testing.io, &input, .{ .history_root = path }));
    var base = try ra8.host.history.base.Base.existingConfigured(gpa, std.testing.io, path, .cache, .{ .recover = false });
    defer base.close();
    var catalog = try ra8.host.history.catalog.Iterator.init(&base);
    try std.testing.expectEqual(null, try catalog.next());
}

test "malformed snapshot sections fail before creating any history storage" {
    var state = std.Io.Writer.Allocating.init(gpa);
    defer state.deinit();
    try ra8.snapshot.file.writeHeader(&state.writer);
    try ra8.snapshot.file.writeSectionHeader(&state.writer, .memory, std.math.maxInt(u64));
    var state_reader = std.Io.Reader.fixed(state.written());
    var out = std.Io.Writer.Allocating.init(gpa);
    defer out.deinit();
    var writer = try bundle.writer.Writer.init(&out.writer, metadata(), .{ .reader = &state_reader, .size = state.written().len }, null);
    try writer.finish();
    var input = std.Io.Reader.fixed(out.written());
    try std.testing.expectError(error.Truncated, importer.open(gpa, std.testing.io, &input, .{ .elf0 = elf }));
}

test "bundle import refuses cross-target snapshot and recording archives before creating history" {
    const machine_mod = ra8.chip.core.machine;
    const sole_m33: machine_mod.Machine = .{
        .name = "sole-m33",
        .label = "SOLE-M33",
        .cores = .{
            .primary = machine_mod.core.cortexM33(.{
                .security = false,
                .fpu = .single,
                .systicks = 1,
            }),
        },
        .part = .ra8d2,
    };
    var archive = try fixture.recording(false);
    defer archive.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(path);
    var input = std.Io.Reader.fixed(archive.bytes.written());
    try std.testing.expectError(
        error.WrongPart,
        importer.open(gpa, std.testing.io, &input, .{
            .history_root = path,
            .expected_board = "ek-ra8d2",
            .machine = &sole_m33,
        }),
    );
    try std.testing.expectError(
        error.Unmarked,
        ra8.host.history.base.Base.existingConfigured(gpa, std.testing.io, path, .cache, .{
            .recover = false,
        }),
    );
}

const Wall = struct {
    ns: u64 = 0,

    fn now(context: *anyopaque) u64 {
        const self: *Wall = @ptrCast(@alignCast(context));
        self.ns += 1_000_000;
        return self.ns;
    }
};
