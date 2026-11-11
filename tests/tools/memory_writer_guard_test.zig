//! Covers tools/memory_writer_guard.zig: repository-wide scan over `src/`,
//! allowlisted H1-H6 / restore / snapshot modules, read-only shadow-oracle
//! rules, and deliberate bypass negative controls.
const std = @import("std");
const guard = @import("memory_writer_guard");

test "live src tree passes memory writer guard with zero findings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const summary = try guard.scanPath(arena.allocator(), std.testing.io, "src", &out.writer);
    if (summary.findings != 0) std.debug.print("{s}\n", .{out.written()});
    try std.testing.expect(summary.scanned > 400);
    try std.testing.expectEqual(@as(usize, 0), summary.findings);
}

test "deliberate bypasses in unapproved src modules are caught" {
    try std.testing.expectEqualStrings(
        ".locateMut(",
        guard.firstViolation("src/session/rogue.zig", "    store.locateMut(0x2000_0000, 4).?.bytes[0] = 1;").?,
    );
    try std.testing.expectEqualStrings(
        ".mutRegion(",
        guard.firstViolation("src/chip/periph/rogue.zig", "    const sram = store.mutRegion(0x2200_0000).?;").?,
    );
    try std.testing.expectEqualStrings(
        ".touchesMut(",
        guard.firstViolation("src/interfaces/rpc/rogue.zig", "    store.touchesMut().invalidate();").?,
    );
    try std.testing.expectEqualStrings(
        ".rawWrite(",
        guard.firstViolation("src/board/rogue.zig", "    try store.rawWrite(0x2200_0000, &.{0xAA});").?,
    );
    try std.testing.expectEqualStrings(
        "store.pages",
        guard.firstViolation("src/session/rogue.zig", "    store.pages[0].?[0] = 0x55;").?,
    );
    try std.testing.expectEqualStrings(
        "extra.windows",
        guard.firstViolation("src/session/rogue.zig", "    const w = store.extra.windows[0];").?,
    );
    try std.testing.expectEqualStrings(
        "port.sdram",
        guard.firstViolation("src/session/rogue.zig", "    port.sdram[0] = 0x99;").?,
    );
    try std.testing.expectEqualStrings(
        "?.sdram",
        guard.firstViolation("src/session/rogue.zig", "    @memset(store.port.?.sdram, 0);").?,
    );
}

test "constCast inside cpu memory module is always rejected" {
    try std.testing.expectEqualStrings(
        "@constCast(",
        guard.firstViolation("src/chip/core/cpu/memory/store.zig", "    return @constCast(&self.touched);").?,
    );
    try std.testing.expectEqualStrings(
        "@constCast(",
        guard.firstViolation("src/chip/core/cpu/memory/extra.zig", "    return @constCast(window.bytes);").?,
    );
}

test "shadow oracle may inspect store.pages read-only but never call mutable hooks" {
    const oracle = "src/session/history/shadow_oracle.zig";
    try std.testing.expect(guard.firstViolation(oracle, "    if (store.pages[index]) |slice| {}") == null);
    try std.testing.expectEqualStrings(
        ".locateMut(",
        guard.firstViolation(oracle, "    _ = store.locateMut(0x2200_0000, 4);").?,
    );
    try std.testing.expectEqualStrings(
        ".rawWrite(",
        guard.firstViolation(oracle, "    try store.rawWrite(0x2200_0000, &.{1});").?,
    );
}

test "read-only capacity queries, comments and string literals do not false-trigger" {
    const metrics = "src/session/device_metrics.zig";
    try std.testing.expect(guard.firstViolation(metrics, "    const cap = port.sdram.len;") == null);
    try std.testing.expect(guard.firstViolation(metrics, "    // store.locateMut(0, 4) and store.pages[0]") == null);
    try std.testing.expect(guard.firstViolation(metrics, "    const msg = \"do not call store.rawWrite(\";") == null);
}

test "directory walker flags deliberate unhooked writer file in scratch src tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "src/chip/core/cpu/memory");
    try tmp.dir.createDirPath(std.testing.io, "src/session");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/chip/core/cpu/memory/store.zig",
        .data = "pub fn ok() void {\n    _ = self.locateMut(0, 4);\n}\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/session/bypass.zig",
        .data = "pub fn bad() void {\n    store.locateMut(0x2200_0000, 4).?.bytes[0] = 0x7E;\n}\n",
    });

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, "src", arena.allocator());
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    const summary = try guard.scanPath(arena.allocator(), std.testing.io, root, &out.writer);
    try std.testing.expectEqual(@as(usize, 2), summary.scanned);
    try std.testing.expectEqual(@as(usize, 1), summary.findings);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "src/session/bypass.zig:2: unapproved backing access \".locateMut(\"") != null);
}
