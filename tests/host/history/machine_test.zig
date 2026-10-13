const std = @import("std");
const machine = @import("ra8").host.history.machine;

test "host lifecycle native owner has nonempty line-safe hostname and process id" {
    var host: [machine.limits.host]u8 = undefined;
    const text = machine.hostName(&host);
    try std.testing.expect(text.len > 0);
    try std.testing.expect(std.mem.indexOfAny(u8, text, "\r\n\x00") == null);
    try std.testing.expect(machine.processId() > 0);
    var boot: [machine.limits.boot]u8 = undefined;
    _ = machine.bootId(std.testing.io, &boot);
}
