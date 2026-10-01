const std = @import("std");
const ra8 = @import("ra8");
const coverage = ra8.core.conformance_coverage;

const claimed = [_][]const u8{ "VADD.F32 T1", "VSUB.F32 T1", "VMUL.F32 T1" };
const covered = [_][]const u8{ "VADD.F32 T1", "VADD.F32 T1", "VMUL.F32 T1" };

test "count is how many vectors name the encoding" {
    try std.testing.expectEqual(@as(usize, 2), coverage.count("VADD.F32 T1", &covered));
    try std.testing.expectEqual(@as(usize, 0), coverage.count("VSUB.F32 T1", &covered));
}

test "the first claimed encoding with no vector is the gap" {
    try std.testing.expectEqualStrings("VSUB.F32 T1", coverage.firstMissing(&claimed, &covered).?);
    try std.testing.expectEqual(@as(?[]const u8, null), coverage.firstMissing(&claimed, &claimed));
}

test "a vector for an encoding nobody claims is caught" {
    const typo = [_][]const u8{ "VADD.F32 T1", "VADD.F23 T1" };
    try std.testing.expectEqualStrings("VADD.F23 T1", coverage.firstUnclaimed(&claimed, &typo).?);
    try std.testing.expectEqual(@as(?[]const u8, null), coverage.firstUnclaimed(&claimed, &covered));
}

test "the table lists every claim in order and marks the gap" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try coverage.writeTable(stream.writer(), &claimed, &covered);
    try std.testing.expectEqualStrings(
        "| Encoding | Vectors |\n|---|---|\n" ++
            "| VADD.F32 T1 | 2 |\n| VSUB.F32 T1 | missing |\n| VMUL.F32 T1 | 1 |\n",
        stream.getWritten(),
    );
}

test "the document says so when nothing is claimed yet" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try coverage.writeDocument(stream.writer(), &.{}, &.{});
    try std.testing.expect(std.mem.startsWith(u8, stream.getWritten(), "# Conformance coverage\n"));
    try std.testing.expect(std.mem.endsWith(u8, stream.getWritten(), "No encodings claimed yet.\n"));
}

test "the document ends with the table once something is claimed" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try coverage.writeDocument(stream.writer(), &claimed, &covered);
    try std.testing.expect(std.mem.endsWith(u8, stream.getWritten(), "| VMUL.F32 T1 | 1 |\n"));
}
