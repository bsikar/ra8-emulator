//! Structural and unit tests for `ra8.session.file_ops` (ADR 0004 D20).
const std = @import("std");
const ra8 = @import("ra8");
const file_ops = ra8.session.file_ops;

const banned_identifiers = [_][]const u8{
    "openFile",
    "createFile",
    "readFile",
    "readFileAlloc",
    "writeFile",
    "deleteFile",
    "createDirPath",
    "fchmodat",
    "posix",
    "fs",
    "cwd",
    "Dir",
    "rename",
};

fn isBannedIdent(ident: []const u8) bool {
    for (banned_identifiers) |word| {
        if (std.mem.eql(u8, ident, word)) return true;
    }
    return false;
}

fn findForbiddenToken(source: [:0]const u8) ?[]const u8 {
    var tok_it = std.zig.Tokenizer.init(source);
    var prev2_tag: ?std.zig.Token.Tag = null;
    var prev2_slice: []const u8 = "";
    var prev1_tag: ?std.zig.Token.Tag = null;
    var prev1_slice: []const u8 = "";
    while (true) {
        const tok = tok_it.next();
        if (tok.tag == .eof) return null;
        const text = source[tok.loc.start..tok.loc.end];
        if (tok.tag == .identifier) {
            if (isBannedIdent(text)) return text;
            if (prev2_tag == .identifier and std.mem.eql(u8, prev2_slice, "Io") and
                prev1_tag == .period and std.mem.eql(u8, text, "File"))
            {
                return "Io.File";
            }
        }
        prev2_tag = prev1_tag;
        prev2_slice = prev1_slice;
        prev1_tag = tok.tag;
        prev1_slice = text;
    }
}

test "ADR 0004 D20 src/session contains zero host file, directory, or POSIX tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;

    var dir = try std.Io.Dir.cwd().openDir(io, "src/session", .{ .iterate = true });
    defer dir.close(io);

    var scanned: usize = 0;
    var it = try dir.walk(alloc);
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const raw = try dir.readFileAlloc(io, entry.path, alloc, .limited(2 << 20));
        const source = try alloc.allocSentinel(u8, raw.len, 0);
        @memcpy(source, raw);
        if (findForbiddenToken(source)) |bad| {
            std.debug.print("forbidden host I/O token '{s}' in src/session/{s}\n", .{ bad, entry.path });
            return error.TestUnexpectedResult;
        }
        scanned += 1;
    }
    try std.testing.expect(scanned >= 100);
}

test "findForbiddenToken catches every banned host I/O construct and ignores comments" {
    const positives = [_][:0]const u8{
        "const d = std.Io.Dir.cwd();",
        "const f = std.Io.File.stdout();",
        "const f = try d.openFile(io, path, .{});",
        "const n = try d.readFile(io, path, &buf);",
        "const b = try d.readFileAlloc(io, path, gpa, .unlimited);",
        "const c = try d.createFile(io, path, .{});",
        "try d.writeFile(io, .{});",
        "try d.deleteFile(io, path);",
        "try d.createDirPath(io, path);",
        "_ = std.posix.system.fchmodat(0, path, 0o700, 0);",
        "const p = try std.fs.path.join(gpa, &.{ a, b });",
        "try d.rename(old, d, new, io);",
    };
    for (positives) |snippet| {
        try std.testing.expect(findForbiddenToken(snippet) != null);
    }
    const clean: [:0]const u8 =
        "// comment mentioning std.Io.Dir, openFile, rename, std.posix, and Io.File\n" ++
        "const Entry = struct { file: Line.File };\n";
    try std.testing.expectEqual(@as(?[]const u8, null), findForbiddenToken(clean));
}

const MemVault = struct {
    written: [64]u8 = undefined,
    written_len: usize = 0,
    state_buf: [64]u8 = undefined,
    state_len: usize = 0,

    fn read(ctx: ?*anyopaque, _: std.Io, _: []const u8, gpa: std.mem.Allocator, max: usize) anyerror![]u8 {
        const self: *MemVault = @ptrCast(@alignCast(ctx.?));
        if (self.written_len > max) return error.StreamTooLong;
        return gpa.dupe(u8, self.written[0..self.written_len]);
    }

    fn write(ctx: ?*anyopaque, _: std.Io, _: []const u8, sctx: *anyopaque, wf: file_ops.WriteStreamFn) anyerror!void {
        const self: *MemVault = @ptrCast(@alignCast(ctx.?));
        var w: std.Io.Writer = .fixed(&self.written);
        try wf(sctx, &w);
        self.written_len = w.end;
    }

    fn save(ctx: ?*anyopaque, _: std.Io, _: ?[]const u8, _: []const u8, sctx: *anyopaque, wf: file_ops.WriteStreamFn) anyerror!void {
        const self: *MemVault = @ptrCast(@alignCast(ctx.?));
        var w: std.Io.Writer = .fixed(&self.state_buf);
        try wf(sctx, &w);
        self.state_len = w.end;
    }

    fn restore(ctx: ?*anyopaque, _: std.Io, gpa: std.mem.Allocator, _: ?[]const u8, _: []const u8, max: usize) anyerror![]u8 {
        const self: *MemVault = @ptrCast(@alignCast(ctx.?));
        if (self.state_len > max) return error.StreamTooLong;
        return gpa.dupe(u8, self.state_buf[0..self.state_len]);
    }

    fn ops(self: *MemVault) file_ops.Ops {
        return .{
            .reader = .{ .context = self, .readFn = read },
            .writer = .{ .context = self, .writeFn = write },
            .state = .{ .context = self, .saveFn = save, .restoreFn = restore },
        };
    }
};

fn writeSlice(ctx: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    const payload: *const []const u8 = @ptrCast(@alignCast(ctx));
    try writer.writeAll(payload.*);
}

test "file_ops in-memory callbacks round-trip reader, writer, and state store" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var vault: MemVault = .{};
    const ops = vault.ops();

    var payload: []const u8 = "report-bytes";
    try ops.writer.writeStream(io, "virtual.json", @ptrCast(&payload), writeSlice);
    const got = try ops.reader.readAlloc(io, "virtual.json", gpa, 32);
    defer gpa.free(got);
    try std.testing.expectEqualStrings("report-bytes", got);

    var snap: []const u8 = "snap-v1";
    try ops.state.save(io, "memdir", "slot0", @ptrCast(&snap), writeSlice);
    const restored = try ops.state.restore(io, gpa, "memdir", "slot0", 32);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings("snap-v1", restored);
}

test "harness.open refuses missing file_ops without elf_bytes and runs in-memory with byte slices" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const elf_path = "tests/fixtures/threadx/threadx_stkof.elf";

    try std.testing.expectError(
        error.NoFileOps,
        ra8.session.harness.open(gpa, io, .{ .elf_path = elf_path, .files = null }),
    );

    const host_reader = ra8.host.session_files.reader(file_ops.Reader);
    const elf_bytes = try host_reader.readAlloc(io, elf_path, gpa, 8 << 20);
    defer gpa.free(elf_bytes);
    const script_bytes = try host_reader.readAlloc(io, "tests/fixtures/display/tap.input", gpa, 64 << 10);
    defer gpa.free(script_bytes);

    var h = try ra8.session.harness.open(gpa, io, .{
        .elf_bytes = elf_bytes,
        .input_script_bytes = script_bytes,
        .history_frames = 2,
        .files = null,
    });
    defer h.deinit();

    _ = try h.session().step(.cpu0);
    try std.testing.expectError(error.NoStateFiles, h.stateFiles().save("slot.snap"));
    try std.testing.expectError(error.NoStateFiles, h.stateFiles().restore("slot.snap"));
}
