const std = @import("std");
const ra8 = @import("ra8");
const bundle = ra8.snapshot.bundle;
const file = ra8.snapshot.file;
const Writer = bundle.writer.Writer;

const metadata: bundle.manifest.Metadata = .{
    .board = "RA8D2",
    .elf0 = .{ .name = "app.elf", .identity = @splat(7), .size = 1234 },
};

fn state() [12]u8 {
    var bytes: [12]u8 = undefined;
    @memcpy(bytes[0..8], &file.magic);
    std.mem.writeInt(u32, bytes[8..12], file.version, .little);
    return bytes;
}

fn source(reader: *std.Io.Reader, size: u64) bundle.writer.Source {
    return .{ .reader = reader, .size = size };
}

fn open(out: *std.Io.Writer, snapshot: *std.Io.Reader, history: bool) !Writer {
    var root = std.Io.Reader.fixed("root");
    var branches = std.Io.Reader.fixed("branches");
    return Writer.init(out, metadata, source(snapshot, 12), if (history) .{
        .root = source(&root, 4),
        .branches = source(&branches, 8),
    } else null);
}

fn entry(it: *std.tar.Iterator, name: []const u8, bytes: []const u8) !void {
    const item = (try it.next()).?;
    try std.testing.expectEqualStrings(name, item.name);
    try std.testing.expectEqual(bytes.len, item.size);
    try std.testing.expectEqual(0o600, item.mode);
    try std.testing.expectEqual(.file, item.kind);
    var buffer: [1024]u8 = undefined;
    var payload = std.Io.Writer.fixed(buffer[0..bytes.len]);
    try it.streamRemaining(item, &payload);
    try std.testing.expectEqualSlices(u8, bytes, buffer[0..bytes.len]);
}

test "recording tar preserves each payload and ends with portable zero blocks" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var snapshot = std.Io.Reader.fixed(&state());
    var writer = try open(&out.writer, &snapshot, true);
    const payload: [513]u8 = @splat(0xab);
    var log = std.Io.Reader.fixed(&payload);
    var object = std.Io.Reader.fixed("checkpoint");
    try writer.add(.log, "events-0", source(&log, payload.len));
    try writer.add(.objects, "pack-0.pack", source(&object, 10));
    try writer.finish();
    try std.testing.expectError(error.InvalidState, writer.finish());

    var input = std.Io.Reader.fixed(out.written());
    var names: [128]u8 = undefined;
    var links: [1]u8 = undefined;
    var it = std.tar.Iterator.init(&input, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    const first = (try it.next()).?;
    try std.testing.expectEqualStrings("manifest.json", first.name);
    var json: [8192]u8 = undefined;
    var json_writer = std.Io.Writer.fixed(json[0..@intCast(first.size)]);
    try it.streamRemaining(first, &json_writer);
    const parsed = try std.json.parseFromSlice(
        bundle.manifest.Manifest,
        std.testing.allocator,
        json[0..@intCast(first.size)],
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value.recording);
    try entry(&it, "state.ra8snap", &state());
    try entry(&it, "recording/root.bin", "root");
    try entry(&it, "recording/branches.bin", "branches");
    try entry(&it, "recording/log/events-0", &payload);
    try entry(&it, "recording/objects/pack-0.pack", "checkpoint");
    try std.testing.expectEqual(null, try it.next());
    try std.testing.expectEqual(0, out.written().len % 512);
    try std.testing.expect(std.mem.allEqual(u8, out.written()[out.written().len - 1024 ..], 0));
}

test "snapshot only archive rejects recording entries and permits finish" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var snapshot = std.Io.Reader.fixed(&state());
    var writer = try open(&out.writer, &snapshot, false);
    var empty = std.Io.Reader.fixed("");
    try std.testing.expectError(error.InvalidState, writer.add(.log, "events-0", source(&empty, 0)));
    try writer.finish();
    try std.testing.expectError(error.InvalidState, writer.add(.log, "events-0", source(&empty, 0)));
}

test "unsafe recording names poison the unfinished output" {
    for ([_][]const u8{ "", ".", "..", "../x", "a/b", "a\\b", "C:x", "a\x00b" }) |bad| {
        var out = std.Io.Writer.Discarding.init(&.{});
        var snapshot = std.Io.Reader.fixed(&state());
        var writer = try open(&out.writer, &snapshot, true);
        var empty = std.Io.Reader.fixed("");
        try std.testing.expectError(error.InvalidName, writer.add(.log, bad, source(&empty, 0)));
        try std.testing.expectError(error.InvalidState, writer.finish());
    }
}

test "duplicate or out of order entries are refused without a footer" {
    for ([_][]const u8{ "events-1", "events-0" }) |next| {
        var out = std.Io.Writer.Discarding.init(&.{});
        var snapshot = std.Io.Reader.fixed(&state());
        var writer = try open(&out.writer, &snapshot, true);
        var empty = std.Io.Reader.fixed("");
        try writer.add(.log, "events-1", source(&empty, 0));
        try std.testing.expectError(error.UnorderedEntry, writer.add(.log, next, source(&empty, 0)));
        try std.testing.expectError(error.InvalidState, writer.finish());
    }
}

test "missing log and short input cannot finish a recording" {
    var out = std.Io.Writer.Discarding.init(&.{});
    var snapshot = std.Io.Reader.fixed(&state());
    var writer = try open(&out.writer, &snapshot, true);
    try std.testing.expectError(error.MissingLog, writer.finish());
    snapshot = std.Io.Reader.fixed(&state());
    writer = try open(&out.writer, &snapshot, true);
    var short = std.Io.Reader.fixed("x");
    try std.testing.expectError(error.EndOfStream, writer.add(.log, "events-0", source(&short, 2)));
    try std.testing.expectError(error.InvalidState, writer.finish());
}

test "invalid snapshot and oversized files are refused before output" {
    var out = std.Io.Writer.Discarding.init(&.{});
    var bytes = state();
    bytes[0] = 'X';
    var snapshot = std.Io.Reader.fixed(&bytes);
    try std.testing.expectError(error.BadMagic, open(&out.writer, &snapshot, false));
    bytes = state();
    bytes[8] +%= 1;
    snapshot = std.Io.Reader.fixed(&bytes);
    try std.testing.expectError(error.BadVersion, open(&out.writer, &snapshot, false));
    try std.testing.expectError(error.FileTooLarge, Writer.init(
        &out.writer,
        metadata,
        source(&snapshot, @as(u64, 1) << 33),
        null,
    ));
    try std.testing.expectEqual(0, out.fullCount());
}

test "destination failures propagate and forbid completion" {
    var buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    var snapshot = std.Io.Reader.fixed(&state());
    var writer = try open(&output, &snapshot, true);
    var payload = std.Io.Reader.fixed(&(@as([2048]u8, @splat(9))));
    try std.testing.expectError(error.WriteFailed, writer.add(.log, "events-0", source(&payload, 2048)));
    try std.testing.expectError(error.InvalidState, writer.finish());
}

const Generated = struct {
    reader: std.Io.Reader = .{ .vtable = &.{ .stream = stream }, .buffer = &.{}, .seek = 0, .end = 0 },
    remaining: u64,
    fail: bool = false,
    calls: usize = 0,

    fn stream(reader: *std.Io.Reader, out: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Generated = @alignCast(@fieldParentPtr("reader", reader));
        if (self.fail) return error.ReadFailed;
        if (self.remaining == 0) return error.EndOfStream;
        const count = @min(limit.minInt64(self.remaining), 4096);
        try out.splatByteAll(0x5a, count);
        self.remaining -= count;
        self.calls += 1;
        return count;
    }
};

test "large recording streams with bounded storage and exact source lengths" {
    var out = std.Io.Writer.Discarding.init(&.{});
    var snapshot = std.Io.Reader.fixed(&state());
    var writer = try open(&out.writer, &snapshot, true);
    const size = 16 * 1024 * 1024 + 513;
    var input: Generated = .{ .remaining = size + 7 };
    try writer.add(.log, "events-0", source(&input.reader, size));
    try writer.finish();
    try std.testing.expectEqual(7, input.remaining);
    try std.testing.expect(input.calls > 4096);
    // Manifest, state, root and branches each occupy a header and one data block.
    const log_blocks = 1 + (size + 511) / 512;
    try std.testing.expectEqual((8 + log_blocks + 2) * 512, out.fullCount());
}

test "read errors and footer errors poison the writer" {
    var out = std.Io.Writer.Discarding.init(&.{});
    var snapshot = std.Io.Reader.fixed(&state());
    var writer = try open(&out.writer, &snapshot, true);
    var input: Generated = .{ .remaining = 1, .fail = true };
    try std.testing.expectError(error.ReadFailed, writer.add(.log, "events-0", source(&input.reader, 1)));
    try std.testing.expectError(error.InvalidState, writer.finish());

    var buffer: [2048]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&buffer);
    snapshot = std.Io.Reader.fixed(&state());
    writer = try open(&fixed, &snapshot, false);
    try std.testing.expectError(error.WriteFailed, writer.finish());
    try std.testing.expectError(error.InvalidState, writer.finish());
}

test "zero and block boundary payloads keep the next tar entry aligned" {
    for ([_]usize{ 0, 511, 512, 513 }) |size| {
        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer out.deinit();
        var snapshot = std.Io.Reader.fixed(&state());
        var writer = try open(&out.writer, &snapshot, true);
        const bytes: [513]u8 = @splat(0x3c);
        var payload = std.Io.Reader.fixed(&bytes);
        var empty = std.Io.Reader.fixed("");
        try writer.add(.log, "events-0", source(&payload, size));
        const leaf: [96]u8 = @splat('x');
        try writer.add(.objects, &leaf, source(&empty, 0));
        try writer.finish();

        var input = std.Io.Reader.fixed(out.written());
        var names: [128]u8 = undefined;
        var links: [1]u8 = undefined;
        var it = std.tar.Iterator.init(&input, .{ .file_name_buffer = &names, .link_name_buffer = &links });
        // Skip manifest, snapshot, root and branches using the iterator's own consumption.
        for (0..4) |_| {
            _ = (try it.next()).?;
        }
        try entry(&it, "recording/log/events-0", bytes[0..size]);
        var path: [128]u8 = undefined;
        try entry(&it, try std.fmt.bufPrint(&path, "recording/objects/{s}", .{leaf}), "");
        try std.testing.expectEqual(null, try it.next());
    }
}

test "source header and tar size bounds fail explicitly" {
    var out = std.Io.Writer.Discarding.init(&.{});
    var short = std.Io.Reader.fixed("short");
    try std.testing.expectError(error.ReaderBufferTooSmall, open(&out.writer, &short, false));
    try std.testing.expectError(error.Truncated, Writer.init(&out.writer, metadata, source(&short, 5), null));
    var snapshot = std.Io.Reader.fixed(&state());
    var writer = try open(&out.writer, &snapshot, true);
    var empty = std.Io.Reader.fixed("");
    try std.testing.expectError(error.FileTooLarge, writer.add(
        .log,
        "events-0",
        source(&empty, @as(u64, 1) << 33),
    ));
    try std.testing.expectError(error.InvalidState, writer.finish());
}
