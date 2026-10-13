const std = @import("std");
const builtin = @import("builtin");
const history = @import("ra8").host.history;
const fixture = @import("root_test.zig");

const io = fixture.io;
const note = history.layout.files.renaming;

test "host lifecycle linked rename moves the bytes, refuses a taken name and leaves no note" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('1');
    defer fixture.Fixture.abandon(&session);
    var log = try session.dir.openDir(io, "log", .{ .iterate = true });
    defer log.close(io);
    try log.writeFile(io, .{ .sub_path = "events.part", .data = "event bytes" });
    try log.writeFile(io, .{ .sub_path = "taken", .data = "taken sentinel" });
    try std.testing.expectError(error.PathAlreadyExists, history.rename.linked(io, session.dir, log, .log, "events.part", "taken"));
    try std.testing.expectError(error.FileNotFound, session.dir.access(io, note, .{}));
    try history.rename.linked(io, session.dir, log, .log, "events.part", "events");
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("event bytes", try log.readFile(io, "events", &buffer));
    try std.testing.expectEqualStrings("taken sentinel", try log.readFile(io, "taken", &buffer));
    try std.testing.expectError(error.FileNotFound, log.access(io, "events.part", .{}));
    try std.testing.expectError(error.FileNotFound, session.dir.access(io, note, .{}));
    try std.testing.expectEqual(@as(u32, 1), (try history.move.file.state(log, "events")).links);
}

test "host lifecycle killed linked rename is ended from its note when the session reopens" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var f = try fixture.Fixture.init();
    defer f.deinit();
    var session = try f.create('2');
    const id = session.id;
    try session.dir.writeFile(io, .{ .sub_path = "log/a.part", .data = "linked bytes" });
    try session.dir.writeFile(io, .{ .sub_path = "log/b.part", .data = "unlinked bytes" });
    try session.keep();
    // Record the immutable intent before the link.
    var log = try session.dir.openDir(io, "log", .{});
    try history.rename.begin(io, session.dir, log, .log, "a.part", "a");
    try history.move.file.link(log, "a.part", log, "a");
    log.close(io);

    fixture.Fixture.abandon(&session);
    session = try history.session.Session.reopen(&f.cache, id);
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("linked bytes", try session.dir.readFile(io, "log/a", &buffer));
    try std.testing.expectError(error.FileNotFound, session.dir.access(io, "log/a.part", .{}));
    try std.testing.expectError(error.FileNotFound, session.dir.access(io, note, .{}));
    // Killed after the note and before the link: nothing has happened.
    log = try session.dir.openDir(io, "log", .{});
    try history.rename.begin(io, session.dir, log, .log, "b.part", "b");
    log.close(io);
    try history.rename.settle(io, session.dir);
    try std.testing.expectEqualStrings("unlinked bytes", try session.dir.readFile(io, "log/b.part", &buffer));
    try std.testing.expectError(error.FileNotFound, session.dir.access(io, "log/b", .{}));
    // Incomplete or conflicting metadata is retained with a precise error.
    try session.dir.writeFile(io, .{ .sub_path = note, .data = "{\"version\":" });
    try std.testing.expectError(error.BadMetadata, history.rename.settle(io, session.dir));
    try std.testing.expectEqualStrings("{\"version\":", try session.dir.readFile(io, note, &buffer));
    try session.dir.deleteFile(io, note);
    log = try session.dir.openDir(io, "log", .{});
    try history.rename.begin(io, session.dir, log, .log, "b.part", "a");
    log.close(io);
    try std.testing.expectError(error.IdentityConflict, history.rename.settle(io, session.dir));
    try std.testing.expectEqualStrings("unlinked bytes", try session.dir.readFile(io, "log/b.part", &buffer));
    try std.testing.expectEqualStrings("linked bytes", try session.dir.readFile(io, "log/a", &buffer));
    fixture.Fixture.abandon(&session);
}
