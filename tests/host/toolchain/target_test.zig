const std = @import("std");
const targets = @import("ra8").host.toolchain.target;

test "toolchain targets inventory vendor image requirements independently of CPU compiler support" {
    const grove = try targets.find("grove-vision-ai-v2");
    try std.testing.expectEqualStrings("101021112", grove.board);
    try std.testing.expect(std.mem.indexOf(u8, grove.image_tools, "image generator") != null);
    try std.testing.expect(std.mem.indexOf(u8, grove.sdk, "Arm GNU and make") != null);
    try std.testing.expectEqualStrings("not applicable", (try targets.find("ra8d2")).npu_tools);
    try std.testing.expectEqualStrings("RTK7FPA8E1S00001BE", (try targets.find("fpb-ra8e1")).board);
    try std.testing.expectEqualStrings("RTK7FPA4T1S00001BE", (try targets.find("fpb-ra4t1")).board);
    try std.testing.expectError(error.UnknownTarget, targets.find("unlisted-board"));
}
