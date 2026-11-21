const std = @import("std");
const cli = @import("cli_app").toolchain;

test "toolchain command preserves explicit override paths and rejects duplicate or incomplete flags" {
    const request = try cli.parse(&.{ "ra8", "toolchain", "plan", "x86_64-windows", "fpb-ra4t1", "--offline", "--backend-zig", "C:/tool with spaces/zig.exe" });
    try std.testing.expect(request.offline);
    try std.testing.expectEqualStrings("C:/tool with spaces/zig.exe", request.backend_zig.?);
    try std.testing.expectError(error.BadArguments, cli.parse(&.{ "ra8", "toolchain", "plan", "x86_64-linux", "ra8d2", "--offline", "--offline" }));
    try std.testing.expectError(error.BadArguments, cli.parse(&.{ "ra8", "toolchain", "plan", "x86_64-linux", "ra8d2", "--cache-root" }));
    try std.testing.expectError(error.BadArguments, cli.parse(&.{ "ra8", "toolchain", "plan", "x86_64-linux", "ra8d2", "--download" }));

    try std.testing.expect((try cli.parseProfiles(&.{ "ra8", "toolchain", "profiles" })) == null);
    try std.testing.expectEqualStrings(
        "fpb-ra8e1",
        (try cli.parseProfiles(&.{ "ra8", "toolchain", "profiles", "fpb-ra8e1" })).?,
    );
    try std.testing.expectError(error.BadArguments, cli.parseProfiles(&.{ "ra8", "toolchain", "profiles", "a", "b" }));
}
