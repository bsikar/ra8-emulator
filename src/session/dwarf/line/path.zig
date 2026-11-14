//! Pure source-path composition and comparison, independent of the debugger host.
const std = @import("std");
const File = @import("header.zig").File;
pub const max_bytes = 4096;

pub fn absolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and separator(path[2], true);
}

fn windowsPath(path: []const u8) bool {
    return std.mem.indexOfScalar(u8, path, '\\') != null or
        (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') or std.mem.startsWith(u8, path, "//");
}

fn separator(byte: u8, windows: bool) bool {
    return byte == '/' or (windows and byte == '\\');
}

fn drive(path: []const u8) bool {
    return path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':';
}

/// Absolute file and include-directory entries take precedence over the CU base.
pub fn write(out: anytype, file: File) !void {
    if (file.name.len == 0) return;
    const windows = windowsPath(file.compilation_directory) or windowsPath(file.directory) or windowsPath(file.name);
    if (!absolute(file.name) and !drive(file.name)) {
        const base = if (absolute(file.directory) or drive(file.directory)) "" else file.compilation_directory;
        if (base.len != 0) {
            try out.writeAll(base);
            if ((file.directory.len != 0 or file.name.len != 0) and !separator(base[base.len - 1], windows) and !(drive(base) and base.len == 2)) try out.writeByte('/');
        }
        if (file.directory.len != 0) {
            try out.writeAll(file.directory);
            if (file.name.len != 0 and !separator(file.directory[file.directory.len - 1], windows) and !(drive(file.directory) and file.directory.len == 2)) try out.writeByte('/');
        }
    }
    try out.writeAll(file.name);
}

pub fn named(file: File, wanted: []const u8) bool {
    if (wanted.len == 0 or file.name.len == 0) return false;
    const windows = windowsPath(file.compilation_directory) or windowsPath(file.directory) or windowsPath(file.name) or windowsPath(wanted);
    var wanted_buffer: [max_bytes]u8 = undefined;
    const query = normalize(wanted, windows, &wanted_buffer) catch return false;
    if (query.len == 0) return false;
    var actual_buffer: [max_bytes]u8 = undefined;
    if (!absolute(wanted)) {
        const name = normalize(file.name, windows, &actual_buffer) catch "";
        if (matches(name, query)) return true;
    }
    var spelling: [max_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&spelling);
    write(&writer, file) catch return false;
    const actual = normalize(writer.buffered(), windows, &actual_buffer) catch return false;
    if (std.mem.eql(u8, actual, query)) return true;
    return !absolute(wanted) and matches(actual, query);
}

fn matches(actual: []const u8, query: []const u8) bool {
    if (std.mem.eql(u8, actual, query)) return true;
    if (actual.len <= query.len) return false;
    return actual[actual.len - query.len - 1] == '/' and std.mem.endsWith(u8, actual, query);
}

fn normalize(path: []const u8, windows: bool, into: []u8) ![]const u8 {
    if (path.len > max_bytes or path.len > into.len) return error.NameTooLong;
    const rooted = path.len != 0 and separator(path[0], windows);
    var used: usize = 0;
    if (rooted) {
        into[used] = '/';
        used += 1;
        if (windows and path.len > 1 and separator(path[1], true)) {
            into[used] = '/';
            used += 1;
        }
    }
    const root_len = used;
    const protected: usize = if (windows and root_len == 2) 2 else if (windows and path.len >= 2 and path[1] == ':') 1 else 0;
    var starts: [max_bytes / 2 + 1]usize = undefined;
    var count: usize = 0;
    var parts = std.mem.tokenizeAny(u8, path, if (windows) "/\\" else "/");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (count <= protected) return error.UnknownParent;
            used = starts[count - 1];
            count -= 1;
            continue;
        }
        const start = used;
        if (used > root_len) {
            into[used] = '/';
            used += 1;
        }
        if (part.len > into.len - used) return error.NameTooLong;
        starts[count] = start;
        count += 1;
        for (part) |byte| {
            into[used] = if (windows) std.ascii.toLower(byte) else byte;
            used += 1;
        }
    }
    return into[0..used];
}
