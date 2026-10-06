const ra8 = @import("ra8");
test "stdio adapter exposes the shared byte transport" {
    var io: ra8.interfaces.rpc.stdio.Stdio = .{};
    const wire = io.transport();
    try @import("std").testing.expect(wire.poll() <= 1);
}
