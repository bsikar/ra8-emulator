//! Covers lazy FP context transfer syntax from DDI0553 C2.4.367-368.
const v81m = @import("v81m.zig");

test "VLLDM and VLSTM T1 print the optional low register list" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEC20, .hw2 = 0x0A00, .text = "vlstm r0, {d0-d15}" },
        .{ .hw1 = 0xEC31, .hw2 = 0x0A00, .text = "vlldm r1, {d0-d15}" },
    });
}

test "VLLDM and VLSTM T2 print the full register list" {
    try v81m.expectTexts(&.{
        .{ .hw1 = 0xEC23, .hw2 = 0x0A80, .text = "vlstm r3, {d0-d31}" },
        .{ .hw1 = 0xEC33, .hw2 = 0x0A80, .text = "vlldm r3, {d0-d31}" },
    });
}
