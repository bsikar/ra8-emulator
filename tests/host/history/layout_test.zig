const std = @import("std");
const history = @import("ra8").host.history;

test "host lifecycle cache tag uses its standard signature and spaces have safe components" {
    try std.testing.expect(std.mem.startsWith(u8, history.layout.root.tag_text, "Signature: 8a477f597d28d172789f06886806bc55\n"));
    for (history.layout.spaces) |space| _ = try history.name.component(@tagName(space));
}
