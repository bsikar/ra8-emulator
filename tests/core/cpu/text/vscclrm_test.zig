//! Covers src/core/cpu/text/vscclrm.zig against the Arm ARM syntax.
const v81m = @import("v81m.zig");

test "VSCCLRM prints the run as a range, then VPR" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEC9F, .hw2 = 0x0A04, .text = "vscclrm {s0-s3, vpr}" },
        .{ .hw1 = 0xECDF, .hw2 = 0x2A01, .text = "vscclrm {s5, vpr}" },
        .{ .hw1 = 0xEC9F, .hw2 = 0x0B10, .text = "vscclrm {d0-d7, vpr}" },
        .{ .hw1 = 0xEC9F, .hw2 = 0x8B10, .text = "vscclrm {d8-d15, vpr}" },
        .{ .hw1 = 0xEC9F, .hw2 = 0x0A00, .text = "vscclrm {vpr}" },
    });
}
