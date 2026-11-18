const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");

const jlink = cli.serve.jlink;
const model = ra8.host.targets;

test "J-Link USB scan matches only pinned serials across reordering drops leases on unplug and gates unwired UART" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const scratch = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(scratch);

    const has_uart = jlink.hostSupportsUart();
    const desc_a: model.Descriptor = .{
        .host_id = "bench",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .probe_serial = "001083322193",
        .transport = jlink.transport,
        .managed = false,
        .operations = if (has_uart) jlink.operations_uart else jlink.operations_debug,
        .capabilities = .{ .hardware_debug = true, .uart = has_uart },
    };
    const desc_b: model.Descriptor = .{
        .host_id = "bench",
        .probe_id = "jlink-b",
        .board_id = "fpb-ra4t1",
        .probe_serial = "001088957027",
        .transport = jlink.transport,
        .managed = false,
        .operations = jlink.operations_debug,
        .capabilities = .{ .hardware_debug = true, .uart = false },
    };
    var probes = [2]jlink.Probe{
        try jlink.configure(std.testing.io, desc_a, .{
            .program = "JLink",
            .scratch = scratch,
            .device = "R7FA8E1AF",
            .cpuid = "0x410FD232",
            .uart_wired = true,
        }),
        try jlink.configure(std.testing.io, desc_b, .{
            .program = "JLink",
            .scratch = scratch,
            .device = "R7FA4T1BB",
            .cpuid = "0x410FD214",
            .uart_wired = false,
        }),
    };
    var registry: model.Registry = .{};
    _ = try registry.add(desc_a, probes[0].provider());
    _ = try registry.add(desc_b, probes[1].provider());

    jlink.apply(&registry, &probes, &.{
        .{ .serial = 1088957027, .product = "J-Link-OB-RA4M2" },
        .{ .serial = 1083322193, .product = "J-Link-OB-RA4M2" },
    });
    const gen_a = registry.entries[0].?.generation;
    const gen_b = registry.entries[1].?.generation;
    var owner: u8 = 0;
    try registry.reserve(&owner, .{
        .host_id = "bench",
        .probe_id = "jlink-a",
        .board_id = "fpb-ra8e1",
        .generation = gen_a,
    });
    try std.testing.expect(probes[0].lease != null);

    // Unplugging serial 1083322193 drops only its lease; 1088957027 stays connected.
    jlink.apply(&registry, &probes, &.{.{ .serial = 1088957027, .product = "J-Link-OB-RA4M2" }});
    try std.testing.expect(probes[0].lease == null);
    try std.testing.expectEqual(.disconnected, registry.entries[0].?.target.connection);
    try std.testing.expectEqual(.connected, registry.entries[1].?.target.connection);
    try std.testing.expect(registry.entries[0].?.generation > gen_a);

    // Unwired VCOM board (FPB-RA4T1) rejects .uart at capability validation before touching hardware.
    var owner_b: u8 = 0;
    const sel_b: model.Selection = .{
        .host_id = "bench",
        .probe_id = "jlink-b",
        .board_id = "fpb-ra4t1",
        .generation = gen_b,
    };
    try registry.reserve(&owner_b, sel_b);
    defer registry.release(&owner_b);
    var out: [256]u8 = undefined;
    try std.testing.expectError(error.Unsupported, registry.perform(&owner_b, sel_b, .uart, &out));
}
