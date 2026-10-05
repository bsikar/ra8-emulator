//! Keeps the camera panel's "Always for this project" across runs
//! (RA8EMU-500). The project is the directory the emulator was started
//! in; the answer lives in one marker file there, so removing the file
//! takes the permission back. A project that cannot be read or written
//! simply asks again, which never opens the webcam unasked.
const std = @import("std");

/// The marker, relative to the project directory.
pub const dir_name = ".ra8-emulator";
pub const file_name = "webcam-always";

/// What the marker holds, so a stray empty file is not read as consent.
pub const contents = "always\n";

/// Whether this project answered Always in an earlier run.
pub fn load(project: std.fs.Dir) bool {
    // One byte spare, so a longer marker reads past `contents` and fails.
    var buf: [contents.len + 1]u8 = undefined;
    const path = dir_name ++ "/" ++ file_name;
    const read = project.readFile(path, &buf) catch return false;
    return std.mem.eql(u8, read, contents);
}

/// Records Always for this project.
pub fn save(project: std.fs.Dir) !void {
    try project.makePath(dir_name);
    try project.writeFile(.{ .sub_path = dir_name ++ "/" ++ file_name, .data = contents });
}
