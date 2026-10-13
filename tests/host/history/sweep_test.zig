const std = @import("std");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

test "host lifecycle next start sweeps stale same-host entries and reports names" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var stale = try f.create('7');
    const id = stale.id;
    try stale.dir.writeFile(fixture.io, .{ .sub_path = "root.bin", .data = "dead data" });
    fixture.Fixture.abandon(&stale);
    var seen: u64 = 0;
    const callback = struct {
        fn report(context: *anyopaque, event: history.sweep.Event) void {
            const counter: *u64 = @ptrCast(@alignCast(context));
            if (event.result) |_| counter.* += 1 else |_| {}
        }
    };
    const result = try history.sweep.run(&f.cache, .{}, .{ .context = &seen, .report = callback.report });
    try std.testing.expectEqual(@as(u64, 1), result.removed);
    try std.testing.expectEqual(@as(u64, 1), seen);
    try std.testing.expectError(error.NotFound, f.cache.owns(&id));
}

test "host lifecycle sweep protects live kept and other-host sessions" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var live = try f.create('8');
    defer _ = live.close(null, .stay) catch @panic("live session cleanup failed");
    var kept = try f.create('9');
    try kept.keep();
    fixture.Fixture.abandon(&kept);
    var remote = try f.create('a');
    try remote.dir.deleteFile(fixture.io, history.layout.files.owner);
    try history.owner.write(fixture.io, remote.dir, .{ .host = "owned-fixture-other-host", .pid = 0 });
    fixture.Fixture.abandon(&remote);
    const result = try history.sweep.run(&f.cache, .{}, null);
    try std.testing.expectEqual(@as(u64, 0), result.removed);
    try std.testing.expectEqual(@as(u64, 2), result.protected);
    try std.testing.expectEqual(@as(u64, 1), result.other_hosts);
    try f.cache.owns(&live.id);
    try f.cache.owns(&kept.id);
    try f.cache.owns(&remote.id);
}

test "host lifecycle resumes trash and ignores young drafts until age threshold" {
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var stale = try f.create('b');
    const id = stale.id;
    fixture.Fixture.abandon(&stale);
    var buffer: history.name.Buffer = undefined;
    const draft = history.name.creating(&buffer, &id);
    try history.move.directory(fixture.allocator, fixture.io, f.cache.dir, &id, f.cache.dir, draft, "");
    try std.testing.expectEqual(@as(u64, 1), (try history.sweep.run(&f.cache, .{}, null)).young);
    const old = try history.sweep.run(&f.cache, .{ .creating_age_s = 0 }, null);
    try std.testing.expectEqual(@as(u64, 1), old.removed);
    var trashed = try f.create('c');
    const trash_id = trashed.id;
    fixture.Fixture.abandon(&trashed);
    const trash = history.name.trash(&buffer, &trash_id);
    try history.move.directory(fixture.allocator, fixture.io, f.cache.dir, &trash_id, f.cache.dir, trash, "");
    try std.testing.expectEqual(@as(u64, 1), (try history.sweep.run(&f.cache, .{}, null)).removed);
    try std.testing.expectError(error.NotFound, f.cache.owns(trash));
}
