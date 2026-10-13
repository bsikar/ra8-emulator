const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle roots have exact markers and cache-only tags" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings(history.layout.root.marker_text, try f.cache.dir.readFile(fixture.io, history.layout.root.marker, &buffer));
    try std.testing.expectEqualStrings(history.layout.root.tag_text, try f.cache.dir.readFile(fixture.io, history.layout.root.tag, &buffer));
    try std.testing.expectError(error.FileNotFound, f.kept.dir.access(fixture.io, history.layout.root.tag, .{}));
    try std.testing.expectError(error.WrongRole, history.base.Base.existing(fixture.allocator, fixture.io, f.cache.path, .kept));
}

test "host lifecycle refuses nonempty unmarked roots empty markers and relative paths" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try std.testing.expectError(error.RelativePath, history.base.Base.open(fixture.allocator, fixture.io, "relative", .cache));
    try f.cache.dir.writeFile(fixture.io, .{ .sub_path = history.layout.root.marker, .data = "" });
    try std.testing.expectError(error.Unmarked, f.cache.checkMarked());
    try std.testing.expectError(error.Unmarked, history.base.Base.existing(fixture.allocator, fixture.io, f.cache.path, .cache));
    try std.testing.expectError(error.Unmarked, history.base.Base.open(fixture.allocator, fixture.io, f.cache.path, .cache));
}

test "host lifecycle recursive boundary requires exact direct child resolution" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('1');
    defer _ = session.close(null, .stay) catch @panic("session cleanup failed");
    try f.cache.owns(&session.id);
    try std.testing.expectError(error.BadName, f.cache.owns("../outside"));
    const child = try f.cache.pathOf(fixture.allocator, &session.id);
    defer fixture.allocator.free(child);
    try std.testing.expect(f.cache.directChild(child, &session.id));
    try std.testing.expect(!f.cache.directChild(f.cache.path, &session.id));
    try std.testing.expect(!f.cache.directChild("C:\\outside\\11111111111111111111111111111111", &session.id));
}

test "host lifecycle lease is made in the root, stays there and is the claim on the name" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('a');
    const id = session.id;
    var buffer: history.name.Buffer = undefined;
    const lease = history.name.lease(&buffer, &id);
    const stat = try f.cache.dir.statFile(fixture.io, lease, .{ .follow_symlinks = false });
    try std.testing.expect(stat.kind == .file);
    try std.testing.expect(stat.size > 0);
    try std.testing.expectError(error.FileNotFound, session.dir.access(fixture.io, history.layout.files.lock, .{}));
    const second = try f.cache.dir.openFile(fixture.io, lease, .{ .mode = .read_write });
    try std.testing.expect(!try second.tryLock(fixture.io, .exclusive));
    second.close(fixture.io);
    try std.testing.expectError(error.IdTaken, f.create('a'));
    try std.testing.expectEqual(history.session.Outcome.deleted, try session.close(null, .stay));
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, lease, .{}));
    // A lease alone holds the name against a new session.
    (try history.lock.create(fixture.io, f.cache.dir, &id)).close(fixture.io);
    try std.testing.expectError(error.IdTaken, f.create('a'));
}

test "host lifecycle crashed session is swept with its lease and a directory without one is protected" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('b');
    const id = session.id;
    fixture.Fixture.abandon(&session);
    var bare = try f.create('c');
    const bare_id = bare.id;
    fixture.Fixture.abandon(&bare);
    var buffer: history.name.Buffer = undefined;
    try f.cache.dir.deleteFile(fixture.io, history.name.lease(&buffer, &bare_id));
    const report = try history.sweep.run(&f.cache, .{}, null);
    try std.testing.expectEqual(@as(u64, 1), report.removed);
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, history.name.lease(&buffer, &id), .{}));
    try std.testing.expectError(error.FileNotFound, f.cache.dir.access(fixture.io, &id, .{}));
    try f.cache.dir.access(fixture.io, &bare_id, .{});
    try std.testing.expectError(error.Unmarked, history.session.Session.reopen(&f.cache, bare_id));
}

test "host lifecycle cache attach preserves valid extended tags and rejects outside hardlinks" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.cache.dir.deleteFile(fixture.io, history.layout.root.tag);
    const tag = "Signature: 8a477f597d28d172789f06886806bc55\n# preserved extra comments\n";
    try history.metadata.ensure(fixture.io, f.cache.dir, history.layout.root.tag, tag);
    var attached = try history.base.Base.existing(fixture.allocator, fixture.io, f.cache.path, .cache);
    attached.close();
    try history.metadata.expect(fixture.io, f.cache.dir, history.layout.root.tag, tag);
    try f.cache.dir.deleteFile(fixture.io, history.layout.root.tag);
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "sentinel", .data = "preserved" });
    try f.hardLink("sentinel", f.cache.dir, history.layout.root.tag);
    try std.testing.expectError(error.OutsideRoot, history.base.Base.existing(fixture.allocator, fixture.io, f.cache.path, .cache));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("preserved", try f.tmp.dir.readFile(fixture.io, "sentinel", &buffer));
}

test "host lifecycle cache attach refuses linked root marker and gate metadata" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "sentinel", .data = "preserved" });
    try f.cache.dir.deleteFile(fixture.io, history.layout.root.gate);
    try f.hardLink("sentinel", f.cache.dir, history.layout.root.gate);
    try std.testing.expectError(error.OutsideRoot, f.cache.gate(.exclusive));
    try f.cache.dir.deleteFile(fixture.io, history.layout.root.gate);
    try f.cache.dir.deleteFile(fixture.io, history.layout.root.marker);
    try f.hardLink("sentinel", f.cache.dir, history.layout.root.marker);
    try std.testing.expectError(error.Unmarked, f.cache.checkMarked());
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("preserved", try f.tmp.dir.readFile(fixture.io, "sentinel", &buffer));
}

test "host lifecycle cache attach rejects metadata symlink and dangling tag without outside writes" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    try f.tmp.dir.writeFile(fixture.io, .{ .sub_path = "sentinel", .data = "preserved" });
    try f.cache.dir.deleteFile(fixture.io, history.layout.root.tag);
    for ([_][]const u8{ "../sentinel", "../missing-sentinel" }) |target| {
        try fixture.symLink(f.cache.dir, target, history.layout.root.tag);
        try std.testing.expectError(error.OutsideRoot, history.base.Base.existing(fixture.allocator, fixture.io, f.cache.path, .cache));
        var buffer: [64]u8 = undefined;
        try std.testing.expectEqualStrings("preserved", try f.tmp.dir.readFile(fixture.io, "sentinel", &buffer));
        try std.testing.expectError(error.FileNotFound, f.tmp.dir.access(fixture.io, "missing-sentinel", .{}));
        try f.cache.dir.deleteFile(fixture.io, history.layout.root.tag);
    }
}
