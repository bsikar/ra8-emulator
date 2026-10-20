//! The read-back of a recorded history from the application's store: one
//! stored file read whole, the way the twice-replay comparison reads a
//! committed log segment and a checkpoint's object (RA8EMU-1196).
const std = @import("std");
const layout = @import("layout.zig");
const storage = @import("storage.zig");

/// Reads one stored file whole. The caller frees the bytes; a file whose
/// length lies (the read runs out before the stated length) refuses
/// rather than handing a shorter read back as if it were whole.
pub fn read(store: storage.Store, space: layout.Space, text: []const u8, gpa: std.mem.Allocator) (std.mem.Allocator.Error || anyerror)![]u8 {
    const file = try store.vtable.open(store.context, space, text, .read);
    defer file.vtable.close(file.context);
    const len = try file.vtable.length(file.context);
    const bytes = try gpa.alloc(u8, @intCast(len));
    errdefer gpa.free(bytes);
    var done: usize = 0;
    while (done < bytes.len) {
        const got = try file.vtable.read(file.context, done, bytes[done..]);
        if (got == 0) return error.ShortRead;
        done += got;
    }
    return bytes;
}
