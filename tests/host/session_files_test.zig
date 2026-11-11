//! Unit tests for `ra8.host.session_files` (ADR 0004 D20, RA8EMU-1175).
const std = @import("std");
const ra8 = @import("ra8");
const session_files = ra8.host.session_files;
const file_ops = ra8.session.file_ops;

test "session_files.bareName rejects path traversal, separators, drives, and NUL bytes" {
    const rejected = [_][]const u8{
        "",
        ".",
        "..",
        "../escape.snap",
        "..\\escape.snap",
        "nested/state.snap",
        "nested\\state.snap",
        "/tmp/abs.snap",
        "\\abs.snap",
        "C:drive.snap",
        "C:\\drive.snap",
        "bad\x00name.snap",
    };
    for (rejected) |bad| {
        try std.testing.expectError(error.BadStatePath, session_files.bareName(bad));
    }

    try session_files.bareName("clean.ra8snap");
    try session_files.bareName("slot-01_ok.state");
}

fn writeHello(ctx: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    const text: *const []const u8 = @ptrCast(@alignCast(ctx));
    try writer.writeAll(text.*);
}

fn writeFail(_: *anyopaque, writer: *std.Io.Writer) anyerror!void {
    try writer.writeAll("partial-bytes");
    return error.SimulatedStreamFailure;
}

test "session_files.inDir confines reader, writer, state round-trip, and temp cleanup" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const ops = session_files.inDir(file_ops.Ops, &tmp.dir);

    var report_text: []const u8 = "fault-summary-ok\n";
    try ops.writer.writeStream(io, "fault.txt", @ptrCast(&report_text), writeHello);
    const read_back = try ops.reader.readAlloc(io, "fault.txt", gpa, 1024);
    defer gpa.free(read_back);
    try std.testing.expectEqualStrings("fault-summary-ok\n", read_back);

    var snap_payload: []const u8 = "RA8SNAP-PAYLOAD";
    try ops.state.save(io, "states", "slot0.snap", @ptrCast(&snap_payload), writeHello);
    const restored = try ops.state.restore(io, gpa, "states", "slot0.snap", 1024);
    defer gpa.free(restored);
    try std.testing.expectEqualStrings("RA8SNAP-PAYLOAD", restored);

    var dummy: u8 = 0;
    try std.testing.expectError(
        error.SimulatedStreamFailure,
        ops.state.save(io, "states", "aborted.snap", @ptrCast(&dummy), writeFail),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(io, "states/aborted.snap", gpa, .limited(64)),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(io, "states/aborted.snap.tmp", gpa, .limited(64)),
    );

    try std.testing.expectError(
        error.BadStatePath,
        ops.state.save(io, "states", "../escape.snap", @ptrCast(&snap_payload), writeHello),
    );
    try std.testing.expectError(
        error.BadStatePath,
        ops.state.restore(io, gpa, "states", "../escape.snap", 1024),
    );
}
