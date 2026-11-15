const std = @import("std");
const ra8 = @import("ra8");

const Reader = ra8.snapshot.bundle.reader.Reader;

test "links directories and GNU extension headers are rejected before payload interpretation" {
    const kinds = [_]std.tar.Writer.Header.FileType{ .symbolic_link, .directory, .gnu_long_name, .gnu_long_link };
    for (kinds) |kind| {
        var out = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer out.deinit();
        var header = std.tar.Writer.Header.init(kind);
        try header.setPath("", "manifest.json");
        try header.write(&out.writer);
        var input = std.Io.Reader.fixed(out.written());
        try std.testing.expectError(error.UnsupportedEntry, Reader.init(std.testing.allocator, &input, .{}));
    }
}

test "bad checksums and incompatible USTAR magic are rejected" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    var header = std.tar.Writer.Header.init(.regular);
    try header.setPath("", "manifest.json");
    try header.write(&out.writer);
    out.written()[0] ^= 1;
    var input = std.Io.Reader.fixed(out.written());
    try std.testing.expectError(error.BadChecksum, Reader.init(std.testing.allocator, &input, .{}));
    header = std.tar.Writer.Header.init(.regular);
    try header.setPath("", "manifest.json");
    header.magic = "ustar!".*;
    out.writer.end = 0;
    try header.write(&out.writer);
    input = std.Io.Reader.fixed(out.written());
    try std.testing.expectError(error.BadTarFormat, Reader.init(std.testing.allocator, &input, .{}));
}
