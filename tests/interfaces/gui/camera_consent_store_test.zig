//! Covers src/interfaces/gui/camera_consent_store.zig: Always for this project kept
//! in a marker file in the project directory.
const std = @import("std");
const ra8 = @import("ra8");
const store = ra8.gui.camera_consent_store;

test "a project with no marker has not answered Always" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(!store.load(std.testing.io, tmp.dir));
}

test "a saved Always loads in the next run, and saving twice is harmless" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try store.save(std.testing.io, tmp.dir);
    try store.save(std.testing.io, tmp.dir);
    try std.testing.expect(store.load(std.testing.io, tmp.dir));
}

test "a marker that does not say always is not consent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, store.dir_name);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = store.dir_name ++ "/" ++ store.file_name, .data = "" });
    try std.testing.expect(!store.load(std.testing.io, tmp.dir));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = store.dir_name ++ "/" ++ store.file_name, .data = "always\nmore\n" });
    try std.testing.expect(!store.load(std.testing.io, tmp.dir));
}
