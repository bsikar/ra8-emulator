//! The host tape folder behind the C6 tape Store (RA8EMU-1020).
const std = @import("std");
const ra8 = @import("ra8");
const tape_dir = ra8.host.tape_dir;

fn scratch(tmp: *std.testing.TmpDir, buf: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buf);
    return buf[0..len];
}

test "a tape written in pieces reads back whole and into a buffer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try scratch(&tmp, &buf);
    const root = try tape_dir.open(std.testing.io, path, true);
    defer tape_dir.release(root);
    const file = try tape_dir.create(root, "a.tape");
    try tape_dir.append(file, "ab");
    try tape_dir.append(file, "cd");
    tape_dir.close(file);

    const whole = try tape_dir.readAlloc(root, "a.tape", std.testing.allocator, 64);
    defer std.testing.allocator.free(whole);
    try std.testing.expectEqualStrings("abcd", whole);
    var out: [8]u8 = undefined;
    try std.testing.expectEqualStrings("abcd", try tape_dir.readInto(root, "a.tape", &out));
}

test "recording makes the folder, replay needs it to exist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try scratch(&tmp, &buf);
    var joined: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&joined, "{s}/tapes", .{base});
    try std.testing.expectError(error.FileNotFound, tape_dir.open(std.testing.io, path, false));
    tape_dir.release(try tape_dir.open(std.testing.io, path, true));
    tape_dir.release(try tape_dir.open(std.testing.io, path, false));
}

test "a missing tape is an error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tape_dir.open(std.testing.io, try scratch(&tmp, &buf), false);
    defer tape_dir.release(root);
    try std.testing.expectError(error.FileNotFound, tape_dir.readAlloc(root, "none.tape", std.testing.allocator, 64));
}
