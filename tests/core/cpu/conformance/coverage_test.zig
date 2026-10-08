const std = @import("std");
const ra8 = @import("ra8");
const coverage = ra8.core.conformance_coverage;

const claimed = [_][]const u8{ "VADD (floating-point)", "VSUB (floating-point)", "VMUL (floating-point)" };
const covered = [_][]const u8{ "VADD (floating-point)", "VADD (floating-point)", "VMUL (floating-point)" };

test "count is how many vectors name the encoding" {
    try std.testing.expectEqual(@as(usize, 2), coverage.count("VADD (floating-point)", &covered));
    try std.testing.expectEqual(@as(usize, 0), coverage.count("VSUB (floating-point)", &covered));
}

test "the first claimed encoding with no vector is the gap" {
    try std.testing.expectEqualStrings("VSUB (floating-point)", coverage.firstMissing(&claimed, &covered).?);
    try std.testing.expectEqual(@as(?[]const u8, null), coverage.firstMissing(&claimed, &claimed));
}

test "a vector for an encoding nobody claims is caught" {
    const typo = [_][]const u8{ "VADD (floating-point)", "VADD.F23 T1" };
    try std.testing.expectEqualStrings("VADD.F23 T1", coverage.firstUnclaimed(&claimed, &typo).?);
    try std.testing.expectEqual(@as(?[]const u8, null), coverage.firstUnclaimed(&claimed, &covered));
}

test "the table lists every claim in order and marks the gap" {
    var buf: [256]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try coverage.writeTable(&stream, &claimed, &covered);
    try std.testing.expectEqualStrings(
        "| Encoding | Vectors |\n|---|---|\n" ++
            "| VADD (floating-point) | 2 |\n| VSUB (floating-point) | missing |\n| VMUL (floating-point) | 1 |\n",
        stream.buffered(),
    );
}

test "the document says so when nothing is claimed yet" {
    var buf: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try coverage.writeDocument(&stream, &.{}, &.{});
    try std.testing.expect(std.mem.startsWith(u8, stream.buffered(), "# Conformance coverage\n"));
    try std.testing.expect(std.mem.endsWith(u8, stream.buffered(), "No encodings claimed yet.\n"));
}

test "the document ends with the table once something is claimed" {
    var buf: [1024]u8 = undefined;
    var stream: std.Io.Writer = .fixed(&buf);
    try coverage.writeDocument(&stream, &claimed, &covered);
    try std.testing.expect(std.mem.endsWith(u8, stream.buffered(), "| VMUL (floating-point) | 1 |\n"));
}
