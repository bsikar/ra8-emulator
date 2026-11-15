//! Recovery through served handlers, including the recorded GUI startup path.
const std = @import("std");
const ra8 = @import("ra8");
const setup = ra8.rpc.served_setup;
const intervene = ra8.rpc.session.intervene;
const handlers = ra8.rpc.session.handlers;
const record = ra8.session.history_record;
const format = ra8.session.history_format;
const image = "tests/fixtures/fpu/fp_basic.elf";
const gpa = std.testing.allocator;
const dual = @import("../regression_rig.zig");

test "recovery handlers refuse an empty undo and restore accepted writes" {
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, null);
    defer served.deinit();
    const session = served.owner.session();
    const original = try session.register(.cpu0, .r0);
    try std.testing.expect(intervene.undoWrite(&served.context, .{ .core = .cpu0 }) == .err);
    try std.testing.expect(handlers.writeRegister(&served.context, .{ .core = .cpu0, .register = .r0, .value = 1234 }) == .ok);
    try std.testing.expect(intervene.undoWrite(&served.context, .{ .core = .cpu0 }) == .ok);
    try std.testing.expectEqual(original, try session.register(.cpu0, .r0));
    try std.testing.expect(handlers.writeRegister(&served.context, .{ .core = .cpu0, .register = .r0, .value = 5678 }) == .ok);
    try std.testing.expect(intervene.resetImage(&served.context, .{ .core = .cpu0 }) == .ok);
    try std.testing.expectEqual(original, try session.register(.cpu0, .r0));
}

test "a queued transport job refuses recovery before the machine starts moving" {
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, null);
    defer served.deinit();
    const session = served.owner.session();
    try session.setRegister(.cpu0, .r0, 1234);
    _ = try served.owner.transport().command(.{ .advance = .{ .core = .cpu0, .ns = 64 } });
    try std.testing.expect(intervene.undoWrite(&served.context, .{ .core = .cpu0 }) == .err);
    try std.testing.expect(intervene.resetImage(&served.context, .{ .core = .cpu0 }) == .err);
    try std.testing.expectEqual(@as(u32, 1234), try session.register(.cpu0, .r0));
    try std.testing.expectEqual(@as(usize, 1), session.history.?.edits.entries.items.len);
}

test "default disk recorded serve recovers repeated writes without detaching history" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root);
    var served: setup.Served = undefined;
    try served.open(gpa, std.testing.io, image, null, .{ .root = root, .checkpoint_every = 1 });
    defer served.deinit();
    const session = served.owner.session();
    const original = try session.register(.cpu0, .r0);
    const bytes = session.history.?.edits.clean.?.bytes.len;
    std.debug.print("recorded recovery initial snapshot: {d} bytes\n", .{bytes});
    try std.testing.expect(bytes <= format.max_len - record.header_len - 6);
    try session.setRegister(.cpu0, .r0, 1111);
    try session.setRegister(.cpu0, .r0, 2222);
    try std.testing.expect(intervene.undoWrite(&served.context, .{ .core = .cpu0 }) == .ok);
    try std.testing.expectEqual(@as(u32, 1111), try session.register(.cpu0, .r0));
    const first_line = session.fork_router.?.active_line;
    try std.testing.expect(first_line != 0);
    try std.testing.expect(intervene.undoWrite(&served.context, .{ .core = .cpu0 }) == .ok);
    try std.testing.expectEqual(original, try session.register(.cpu0, .r0));
    try std.testing.expect(session.fork_router.?.active_line != first_line);
    try std.testing.expect(intervene.resetImage(&served.context, .{ .core = .cpu0 }) == .ok);
    try std.testing.expect(session.persistent_recorder != null);
    try std.testing.expect(!served.history.?.detached);
    try session.persistent_recorder.?.force();
    const bridge = served.owner.transport().history.?;
    const log = try bridge.logBytes.?(bridge.context);
    var at: usize = 0;
    var restores: usize = 0;
    while (at < log.len) {
        const frame = try format.decode(log[at..]);
        at += frame.consumed;
        if (frame.frame.kind != @backingInt(record.Kind.intervention)) continue;
        const entry = try record.decodeIntervention(frame.frame.payload);
        if (entry.intervention.what == .state_restore) restores += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), restores);
}

test "clean reset retains both startup CPUs and the admitted SD image" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const media = try gpa.alloc(u8, 512 * 1024);
    defer gpa.free(media);
    @memset(media, 0x5A);
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "card.img", .data = media });
    const card = try temp.dir.realPathFileAlloc(std.testing.io, "card.img", gpa);
    defer gpa.free(card);
    const histories = [_]?setup.HistoryOpts{ null, .{ .ram_budget = 256 * 1024 * 1024 } };
    for (histories) |history| {
        var served: setup.Served = undefined;
        try served.openInputs(gpa, std.testing.io, dual.dual_image, null, history, .{ .bytes = dual.dual_second }, .{ .card = .{ .image = card } });
        defer served.deinit();
        const session = served.owner.session();
        const first = try session.register(.cpu0, .r0);
        const second = try session.register(.cpu1, .r0);
        try session.setRegister(.cpu0, .r0, 111);
        try session.setRegister(.cpu1, .r0, 222);
        const changed: [512]u8 = @splat(0xA5);
        try std.testing.expect(served.owner.board().host_card.write(0, &changed));
        try session.resetImage();
        try std.testing.expectEqual(first, try session.register(.cpu0, .r0));
        try std.testing.expectEqual(second, try session.register(.cpu1, .r0));
        var restored: [512]u8 = undefined;
        try std.testing.expect(served.owner.board().host_card.read(0, &restored));
        try std.testing.expectEqualSlices(u8, media[0..512], &restored);
        if (history != null) try std.testing.expect(session.persistent_recorder != null);
    }
}
