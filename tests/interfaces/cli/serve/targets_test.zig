const builtin = @import("builtin");
const std = @import("std");

const cli = @import("cli_app");
const ra8 = @import("ra8");

test "target bindings require explicit opt in and cannot survive artifact replacement" {
    try std.testing.expect(cli.serve.main.parse(&.{ "emu", "serve", "--stdio", "fw.elf" }).?.targets == null);
    const args = &.{ "emu", "serve", "--targets", "bindings.json", "--stdio", "fw.elf" };
    try std.testing.expectEqualStrings("bindings.json", cli.serve.main.parse(args).?.targets.?);
    const both = &.{ "emu", "serve", "--targets", "bindings.json", "--artifacts-root", ".", "--stdio", "fw.elf" };
    try std.testing.expect(cli.serve.main.parse(both) == null);
}

test "operator bindings cannot advertise unimplemented flash build or NPU capabilities" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text = "[{\"kind\":\"rsp\",\"host\":\"127.0.0.1\",\"port\":1234,\"target\":{" ++
        "\"managed\":false,\"host_id\":\"host\",\"board_id\":\"board\",\"probe_id\":\"probe\",\"transport\":\"rsp\"," ++
        "\"capabilities\":{\"flash\":true,\"build\":true,\"npu\":true}}}]";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bindings.json", .data = text });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "bindings.json", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var inventory: cli.target_bindings.Inventory = .{};
    defer inventory.close();
    var session: ra8.session.api.Session = undefined;
    try inventory.open(std.testing.allocator, std.testing.io, path, &session);
    const caps = inventory.registry.entries[0].?.target.capabilities;
    try std.testing.expect(caps.hardware_debug);
    try std.testing.expect(!caps.flash and !caps.build and !caps.npu and !caps.emulation);
}

test "jlink and agent bindings require pinned serials absolute paths and unique endpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const dup_serial =
        "[{\"kind\":\"jlink\",\"program\":\"JLink\",\"scratch\":\"" ++
        (if (builtin.os.tag == .windows) "C:\\\\tmp" else "/tmp") ++
        "\",\"device\":\"Cortex-M85\",\"cpuid\":\"0x410FD232\",\"target\":{" ++
        "\"managed\":false,\"host_id\":\"h\",\"board_id\":\"b1\",\"probe_id\":\"p1\"," ++
        "\"probe_serial\":\"001083322193\",\"transport\":\"jlink-usb\"}}," ++
        "{\"kind\":\"jlink\",\"program\":\"JLink\",\"scratch\":\"" ++
        (if (builtin.os.tag == .windows) "C:\\\\tmp" else "/tmp") ++
        "\",\"device\":\"Cortex-M33\",\"cpuid\":\"0x410FD214\",\"target\":{" ++
        "\"managed\":false,\"host_id\":\"h\",\"board_id\":\"b2\",\"probe_id\":\"p2\"," ++
        "\"probe_serial\":\"1083322193\",\"transport\":\"jlink-usb\"}}]";
    try tmp.dir.writeFile(io, .{ .sub_path = "dup.json", .data = dup_serial });
    const dup_path = try tmp.dir.realPathFileAlloc(io, "dup.json", alloc);
    defer alloc.free(dup_path);
    var inventory: cli.target_bindings.Inventory = .{};
    defer inventory.close();
    try std.testing.expectError(error.DuplicateIdentity, inventory.open(alloc, io, dup_path, null));
}

fn expectBindingError(
    tmp: *std.testing.TmpDir,
    name: []const u8,
    items: []const cli.target_bindings.Binding,
    expected: anyerror,
) !void {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const raw = try std.json.Stringify.valueAlloc(alloc, items, .{});
    defer alloc.free(raw);
    try tmp.dir.writeFile(io, .{ .sub_path = name, .data = raw });
    const path = try tmp.dir.realPathFileAlloc(io, name, alloc);
    defer alloc.free(path);
    var inventory: cli.target_bindings.Inventory = .{};
    defer inventory.close();
    try std.testing.expectError(expected, inventory.open(alloc, io, path, null));
}

fn testDescriptor(host_id: []const u8, board_id: []const u8, probe_id: []const u8, serial: []const u8) ra8.host.targets.Descriptor {
    return .{
        .managed = false,
        .host_id = host_id,
        .board_id = board_id,
        .probe_id = probe_id,
        .probe_serial = serial,
        .transport = "jlink-usb",
    };
}

test "agent bindings reject mixed tcp-and-profile fields and mismatched specs under one host_id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    try tmp.dir.writeFile(io, .{
        .sub_path = "secret.key",
        .data = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts-a", .data = "ssh bench box-a emulator=/nope/ra8\nssh alt box-b emulator=/nope/ra8\n" });
    const secret_path = try tmp.dir.realPathFileAlloc(io, "secret.key", alloc);
    defer alloc.free(secret_path);
    const hosts_a = try tmp.dir.realPathFileAlloc(io, "hosts-a", alloc);
    defer alloc.free(hosts_a);
    const desc_a = testDescriptor("host-1", "board-1", "probe-1", "001083322193");
    const desc_b = testDescriptor("host-1", "board-2", "probe-2", "001088957027");

    try expectBindingError(&tmp, "mixed-prof.json", &.{.{
        .kind = .agent,
        .host = "127.0.0.1",
        .port = 9999,
        .profile = "bench",
        .hosts_file = hosts_a,
        .remote_targets = "/etc/t.json",
        .secret_file = secret_path,
        .target = desc_a,
    }}, error.InvalidEndpoint);
    try expectBindingError(&tmp, "mixed-tcp.json", &.{.{
        .kind = .agent,
        .host = "127.0.0.1",
        .port = 9999,
        .remote_targets = "/etc/t.json",
        .secret_file = secret_path,
        .target = desc_a,
    }}, error.InvalidEndpoint);
    try expectBindingError(&tmp, "mismatch-prof.json", &.{
        .{ .kind = .agent, .profile = "bench", .hosts_file = hosts_a, .remote_targets = "/etc/t.json", .secret_file = secret_path, .target = desc_a },
        .{ .kind = .agent, .profile = "alt", .hosts_file = hosts_a, .remote_targets = "/etc/t.json", .secret_file = secret_path, .target = desc_b },
    }, error.InvalidEndpoint);
    try expectBindingError(&tmp, "mismatch-secret.json", &.{
        .{ .kind = .agent, .profile = "bench", .hosts_file = hosts_a, .remote_targets = "/etc/t.json", .secret_file = secret_path, .target = desc_a },
        .{ .kind = .agent, .profile = "bench", .hosts_file = hosts_a, .remote_targets = "/etc/t.json", .remote_secret_file = "/etc/other.key", .secret_file = secret_path, .target = desc_b },
    }, error.InvalidEndpoint);
}

test "agent profile uniqueness scopes profile names by hosts_file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    try tmp.dir.writeFile(io, .{
        .sub_path = "secret.key",
        .data = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts-a", .data = "ssh bench box-a emulator=/nope/ra8\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "hosts-b", .data = "ssh bench box-c emulator=/nope/ra8\n" });
    const secret_path = try tmp.dir.realPathFileAlloc(io, "secret.key", alloc);
    defer alloc.free(secret_path);
    const hosts_a = try tmp.dir.realPathFileAlloc(io, "hosts-a", alloc);
    defer alloc.free(hosts_a);
    const hosts_b = try tmp.dir.realPathFileAlloc(io, "hosts-b", alloc);
    defer alloc.free(hosts_b);
    const desc_a = testDescriptor("host-1", "board-1", "probe-1", "001083322193");
    const desc_c = testDescriptor("host-2", "board-3", "probe-3", "001088957027");

    try expectBindingError(&tmp, "dup-prof.json", &.{
        .{ .kind = .agent, .profile = "bench", .hosts_file = hosts_a, .remote_targets = "/etc/t.json", .secret_file = secret_path, .target = desc_a },
        .{ .kind = .agent, .profile = "bench", .hosts_file = hosts_a, .remote_targets = "/etc/t.json", .secret_file = secret_path, .target = desc_c },
    }, error.DuplicateEndpoint);

    const distinct_raw = try std.json.Stringify.valueAlloc(alloc, &[_]cli.target_bindings.Binding{
        .{ .kind = .agent, .profile = "bench", .hosts_file = hosts_a, .remote_targets = "/etc/t.json", .secret_file = secret_path, .target = desc_a },
        .{ .kind = .agent, .profile = "bench", .hosts_file = hosts_b, .remote_targets = "/etc/t.json", .secret_file = secret_path, .target = desc_c },
    }, .{});
    defer alloc.free(distinct_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "distinct-hosts.json", .data = distinct_raw });
    const distinct_path = try tmp.dir.realPathFileAlloc(io, "distinct-hosts.json", alloc);
    defer alloc.free(distinct_path);
    var inventory: cli.target_bindings.Inventory = .{};
    defer inventory.close();
    try inventory.open(alloc, io, distinct_path, null);
    try std.testing.expectEqual(@as(usize, 2), inventory.agent_host_count);
}

test "jlink flash_enabled requires bounded flash window and non-jlink kinds reject flash fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const desc = testDescriptor("host-1", "fpb-ra8e1", "jlink-a", "001083322193");
    const scratch_dir = if (builtin.os.tag == .windows) "C:\\tmp" else "/tmp";

    try expectBindingError(&tmp, "rsp-flash.json", &.{.{
        .kind = .rsp,
        .host = "127.0.0.1",
        .port = 2331,
        .flash_enabled = true,
        .flash_size = 4096,
        .target = .{ .managed = false, .host_id = "h", .board_id = "b", .probe_id = "p", .transport = "rsp" },
    }}, error.InvalidEndpoint);

    try expectBindingError(&tmp, "jlink-zero-win.json", &.{.{
        .kind = .jlink,
        .program = "JLink",
        .scratch = scratch_dir,
        .device = "R7FA8E1AF",
        .cpuid = "0x410FD232",
        .flash_enabled = true,
        .flash_base = 0x0200_0000,
        .flash_size = 0,
        .target = desc,
    }}, error.InvalidEndpoint);
}

test "use_board_profile populates arrived Renesas board parameters and refuses absent or bootloader-only boards" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const scratch_dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(scratch_dir);

    const valid_raw = try std.json.Stringify.valueAlloc(alloc, &[_]cli.target_bindings.Binding{
        .{
            .kind = .jlink,
            .program = "JLink",
            .scratch = scratch_dir,
            .use_board_profile = true,
            .target = testDescriptor("bench", "fpb-ra8e1", "jlink-e1", "001083322193"),
        },
        .{
            .kind = .jlink,
            .program = "JLink",
            .scratch = scratch_dir,
            .use_board_profile = true,
            .target = testDescriptor("bench", "fpb-ra4t1", "jlink-t1", "001088957027"),
        },
    }, .{});
    defer alloc.free(valid_raw);
    try tmp.dir.writeFile(io, .{ .sub_path = "profiles.json", .data = valid_raw });
    const valid_path = try tmp.dir.realPathFileAlloc(io, "profiles.json", alloc);
    defer alloc.free(valid_path);

    var inventory: cli.target_bindings.Inventory = .{};
    defer inventory.close();
    try inventory.open(alloc, io, valid_path, null);
    try std.testing.expectEqual(@as(usize, 2), inventory.probe_count);
    try std.testing.expectEqualStrings("R7FA8E1AFDCFB", inventory.probes[0].part.expected);
    try std.testing.expectEqual(@as(u32, 0x0200_0000), inventory.probes[0].flash_base);
    try std.testing.expectEqualStrings("R7FA4T1BB3CFM", inventory.probes[1].part.expected);
    try std.testing.expect(!inventory.probes[1].uart_wired);

    for ([_][]const u8{ "grove-vision-ai-v2", "ra8d2", "ra8p1" }) |absent| {
        try expectBindingError(&tmp, "absent.json", &.{.{
            .kind = .jlink,
            .program = "JLink",
            .scratch = scratch_dir,
            .use_board_profile = true,
            .target = testDescriptor("bench", absent, "jlink-x", "001083322193"),
        }}, error.ProfileUnavailable);
    }
}
