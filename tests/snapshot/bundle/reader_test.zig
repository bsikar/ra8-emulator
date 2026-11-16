const std = @import("std");
const ra8 = @import("ra8");

const bundle = ra8.snapshot.bundle;
const Reader = bundle.reader.Reader;
const metadata: bundle.manifest.Metadata = .{
    .board = "test-board",
    .elf0 = .{ .name = "test.elf", .identity = @splat(1), .size = 4 },
};

fn archive() !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer out.deinit();
    var state = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer state.deinit();
    try ra8.snapshot.file.writeHeader(&state.writer);
    var input = std.Io.Reader.fixed(state.written());
    var writer = try bundle.writer.Writer.init(&out.writer, metadata, .{ .reader = &input, .size = 12 }, null);
    try writer.finish();
    return out;
}

test "reader admits a writer archive and consumes entries without buffering the archive" {
    var out = try archive();
    defer out.deinit();
    var input = std.Io.Reader.fixed(out.written());
    var reader = try Reader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    try std.testing.expectEqualStrings("test-board", reader.metadata.value.board);
    const entry = (try reader.next()).?;
    try std.testing.expectEqual(.snapshot, entry.kind);
    try std.testing.expectEqualStrings("state.ra8snap", entry.name);
    const state = try reader.readAlloc(std.testing.allocator, 12);
    defer std.testing.allocator.free(state);
    _ = try ra8.snapshot.file.Reader.open(state);
    try std.testing.expectEqual(null, try reader.next());
    try std.testing.expectEqual(null, try reader.next());
}

test "unconsumed entries and sink errors poison admission" {
    var out = try archive();
    defer out.deinit();
    var input = std.Io.Reader.fixed(out.written());
    var reader = try Reader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    _ = try reader.next();
    try std.testing.expectError(error.EntryNotConsumed, reader.next());
    try std.testing.expectError(error.InvalidState, reader.next());

    input = std.Io.Reader.fixed(out.written());
    var other = try Reader.init(std.testing.allocator, &input, .{});
    defer other.deinit();
    _ = try other.next();
    var tiny = std.Io.Writer.fixed(&.{});
    try std.testing.expectError(error.WriteFailed, other.copy(&tiny));
    try std.testing.expectError(error.InvalidState, other.next());
}

test "file total entry and allocation budgets are checked before payload reads" {
    var out = try archive();
    defer out.deinit();
    var input = std.Io.Reader.fixed(out.written());
    try std.testing.expectError(error.TooLarge, Reader.init(std.testing.allocator, &input, .{ .file_bytes = 1 }));
    input = std.Io.Reader.fixed(out.written());
    try std.testing.expectError(error.TooLarge, Reader.init(std.testing.allocator, &input, .{ .total_bytes = 511 }));
    input = std.Io.Reader.fixed(out.written());
    var reader = try Reader.init(std.testing.allocator, &input, .{ .entries = 1 });
    defer reader.deinit();
    try std.testing.expectError(error.TooLarge, reader.next());
    input = std.Io.Reader.fixed(out.written());
    var other = try Reader.init(std.testing.allocator, &input, .{});
    defer other.deinit();
    _ = try other.next();
    try std.testing.expectError(error.TooLarge, other.readAlloc(std.testing.allocator, 11));
}

test "every truncation of a complete bundle is rejected" {
    var out = try archive();
    defer out.deinit();
    for (0..out.written().len) |length| {
        var input = std.Io.Reader.fixed(out.written()[0..length]);
        var reader = Reader.init(std.testing.allocator, &input, .{}) catch continue;
        defer reader.deinit();
        var sink = std.Io.Writer.Discarding.init(&.{});
        consume(&reader, &sink.writer) catch continue;
        return error.AcceptedTruncation;
    }
}

fn consume(reader: *Reader, out: *std.Io.Writer) !void {
    while (try reader.next()) |_| {
        try reader.copy(out);
    }
}

test "nonzero padding missing terminator and trailing data are rejected" {
    var out = try archive();
    defer out.deinit();
    const mutations = [_]usize{ 2047, 2560, 3071 };
    for (mutations) |at| {
        out.written()[at] = 1;
        var input = std.Io.Reader.fixed(out.written());
        var reader = try Reader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        var sink = std.Io.Writer.Discarding.init(&.{});
        try std.testing.expectError(if (at == 2047) error.BadPadding else error.BadTerminator, consume(&reader, &sink.writer));
        out.written()[at] = 0;
    }
    try out.writer.writeByte(1);
    var input = std.Io.Reader.fixed(out.written());
    var reader = try Reader.init(std.testing.allocator, &input, .{});
    defer reader.deinit();
    var sink = std.Io.Writer.Discarding.init(&.{});
    try std.testing.expectError(error.TrailingData, consume(&reader, &sink.writer));
}

fn extraEntry(path: []const u8) !std.Io.Writer.Allocating {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    errdefer out.deinit();
    var tar: std.tar.Writer = .{ .underlying_writer = &out.writer };
    var buffer: [8192]u8 = undefined;
    const json = try bundle.manifest.encode(&buffer, metadata, true);
    try tar.writeFileBytes("manifest.json", json, .{});
    for ([_][]const u8{ "state.ra8snap", "recording/root.bin", "recording/branches.bin", "recording/log/events-0", path }) |name| {
        try tar.writeFileBytes(name, "", .{});
    }
    try tar.finishPedantically();
    return out;
}

test "untrusted recording paths cannot escape or replace prior entries" {
    const Case = struct { path: []const u8, err: anyerror };
    const cases = [_]Case{
        .{ .path = "recording/log/../escape", .err = error.InvalidName },
        .{ .path = "recording/log/C:escape", .err = error.InvalidName },
        .{ .path = "recording/log/a\\b", .err = error.InvalidName },
        .{ .path = "recording/log/events-0", .err = error.BadEntryOrder },
        .{ .path = "recording/root.bin", .err = error.UnexpectedEntry },
        .{ .path = "/absolute", .err = error.UnexpectedEntry },
    };
    for (cases) |case| {
        var out = try extraEntry(case.path);
        defer out.deinit();
        var input = std.Io.Reader.fixed(out.written());
        var reader = try Reader.init(std.testing.allocator, &input, .{});
        defer reader.deinit();
        var sink = std.Io.Writer.Discarding.init(&.{});
        try std.testing.expectError(case.err, consume(&reader, &sink.writer));
        try std.testing.expectError(error.InvalidState, reader.next());
    }
}

test "the total budget includes both terminating blocks" {
    var out = try archive();
    defer out.deinit();
    var input = std.Io.Reader.fixed(out.written());
    var reader = try Reader.init(std.testing.allocator, &input, .{ .total_bytes = out.written().len - 1 });
    defer reader.deinit();
    var sink = std.Io.Writer.Discarding.init(&.{});
    try std.testing.expectError(error.TooLarge, consume(&reader, &sink.writer));
}

test "standard USTAR zero record padding is accepted within the byte budget" {
    var out = try archive();
    defer out.deinit();
    try out.writer.splatByteAll(0, 1024);
    var input = std.Io.Reader.fixed(out.written());
    var reader = try Reader.init(std.testing.allocator, &input, .{ .total_bytes = out.written().len });
    defer reader.deinit();
    var sink = std.Io.Writer.Discarding.init(&.{});
    try consume(&reader, &sink.writer);
    input = std.Io.Reader.fixed(out.written());
    var limited = try Reader.init(std.testing.allocator, &input, .{ .total_bytes = out.written().len - 1 });
    defer limited.deinit();
    try std.testing.expectError(error.TooLarge, consume(&limited, &sink.writer));
}
