const builtin = @import("builtin");
const std = @import("std");

const ctl_run = @import("../ctl_run.zig");
const paths = @import("test_paths");
const serve_peer = @import("../serve_peer.zig");
const targets = @import("cli_app").target_ctl;

fn writeFakeJlink(tmp: *std.testing.TmpDir, alloc: std.mem.Allocator) ![:0]u8 {
    const io = std.testing.io;
    if (builtin.os.tag == .windows) {
        const script =
            "@echo off\r\n" ++
            "if \"%~5\"==\"-CommandFile\" (\r\n" ++
            "  echo J-Link[0]: Connection: USB, Serial number: 1083322193, ProductName: J-Link-OB-RA4M2\r\n" ++
            "  exit /b 0\r\n" ++
            ")\r\n" ++
            "echo S/N: 1083322193\r\n" ++
            "echo E000ED00 = 410FD232 \r\n" ++
            "echo Verify successful.\r\n" ++
            "exit /b 0\r\n";
        try tmp.dir.writeFile(io, .{ .sub_path = "fake_jlink.cmd", .data = script });
        return tmp.dir.realPathFileAlloc(io, "fake_jlink.cmd", alloc);
    }
    const script =
        "#!/bin/sh\n" ++
        "if [ \"$5\" = \"-CommandFile\" ]; then\n" ++
        "  echo 'J-Link[0]: Connection: USB, Serial number: 1083322193, ProductName: J-Link-OB-RA4M2'\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "echo 'S/N: 1083322193'\n" ++
        "echo 'E000ED00 = 410FD232 '\n" ++
        "echo 'Verify successful.'\n" ++
        "exit 0\n";
    var file = try tmp.dir.createFile(io, "fake_jlink.sh", .{ .permissions = .fromMode(0o755) });
    defer file.close(io);
    try file.writeStreamingAll(io, script);
    return tmp.dir.realPathFileAlloc(io, "fake_jlink.sh", alloc);
}

test "target CLI requires stable identity generation disambiguation and known actions" {
    try std.testing.expectEqual(targets.Command.list, try targets.parse(&.{"list"}));
    const cmd = try targets.parse(&.{ "use", "host", "probe", "board", "42", "-", "registers", "step" });
    try std.testing.expectEqual(@as(u64, 42), cmd.use.selection.generation);
    try std.testing.expectEqualStrings("", cmd.use.selection.disambiguation);
    try std.testing.expectEqual(@as(usize, 2), cmd.use.count);
    try std.testing.expectError(error.BadArguments, targets.parse(&.{ "use", "host", "probe", "board", "0", "-", "step" }));
    try std.testing.expectError(error.BadArguments, targets.parse(&.{ "use", "host", "probe", "board", "2", "-", "erase" }));
    try std.testing.expectError(error.BadArguments, targets.parse(&.{"0"}));

    const flash_cmd = try targets.parse(&.{
        "flash", "win-bench", "jlink-a", "fpb-ra8e1", "9", "-", "--elf", "fw.elf", "--reset", "--uart",
    });
    try std.testing.expectEqualStrings("fw.elf", flash_cmd.flash.source.elf);
    try std.testing.expect(flash_cmd.flash.reset and flash_cmd.flash.uart);

    const rec_cmd = try targets.parse(&.{
        "flash-receipt", "win-bench", "jlink-a", "fpb-ra8e1", "9", "-", "--receipt", ".ra8-builds/a/project.json",
    });
    try std.testing.expectEqualStrings(".ra8-builds/a/project.json", rec_cmd.flash.source.receipt);
    try std.testing.expectError(error.BadArguments, targets.parse(&.{ "flash", "h", "p", "b", "9", "-" }));
}

test "target CLI lists selects operates and releases through a real TCP RPC connection" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const config = "[{\"kind\":\"emulator\",\"target\":{\"managed\":false," ++
        "\"host_id\":\"fixture-host\",\"probe_id\":\"virtual\",\"board_id\":\"emu-a\"," ++
        "\"transport\":\"in-process\",\"identity_verified\":true}}]";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "targets.json", .data = config });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "targets.json", gpa);
    defer gpa.free(path);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listenArgs(&.{ paths.emulator, "serve", "--targets", path, "--listen", "tcp:127.0.0.1:0", serve_peer.image_path }, &line);
    defer served.child.kill(std.testing.io);
    var listing = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer listing.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, listing.term);
    const entries = listing.parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    const generation = entries[0].object.get("generation").?.integer;
    const text = try std.fmt.allocPrint(gpa, "{d}", .{generation});
    defer gpa.free(text);
    var operated = try ctl_run.run(gpa, served.bound, &.{ "targets", "use", "fixture-host", "virtual", "emu-a", text, "-", "registers" });
    defer operated.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, operated.term);
    try std.testing.expect(operated.field("pc").integer != 0);
    var after = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer after.deinit();
    try std.testing.expect(!after.parsed.value.array.items[0].object.get("reserved").?.bool);
    var failed = try ctl_run.run(gpa, served.bound, &.{ "targets", "use", "fixture-host", "virtual", "emu-a", text, "-", "flash" });
    defer failed.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, failed.term);
    var final = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer final.deinit();
    try std.testing.expect(!final.parsed.value.array.items[0].object.get("reserved").?.bool);
}

test "target CLI flash preserves valid JSON reply across automatic reservation release" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const prog = try writeFakeJlink(&tmp, gpa);
    defer gpa.free(prog);
    const scratch = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(scratch);
    const elf_path = try std.fs.path.join(gpa, &.{ "tests", "fixtures", "known_state", "fpb_ra8e1.elf" });
    defer gpa.free(elf_path);

    var cfg_buf: [2048]u8 = undefined;
    var cfg_writer = std.Io.Writer.fixed(&cfg_buf);
    try cfg_writer.writeAll("[{\"kind\":\"jlink\",\"program\":");
    try std.json.Stringify.encodeJsonString(prog, .{}, &cfg_writer);
    try cfg_writer.writeAll(",\"scratch\":");
    try std.json.Stringify.encodeJsonString(scratch, .{}, &cfg_writer);
    try cfg_writer.writeAll(",\"device\":\"R7FA8E1AF\",\"cpuid\":\"0x410FD232\",\"flash_enabled\":true," ++
        "\"flash_base\":33554432,\"flash_size\":1048576,\"target\":{\"managed\":false,\"host_id\":\"bench\"," ++
        "\"probe_id\":\"jlink-a\",\"board_id\":\"fpb-ra8e1\",\"probe_serial\":\"001083322193\",\"transport\":\"jlink-usb\"}}]");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "flash_targets.json", .data = cfg_writer.buffered() });
    const cfg_path = try tmp.dir.realPathFileAlloc(std.testing.io, "flash_targets.json", gpa);
    defer gpa.free(cfg_path);

    var line: [256]u8 = undefined;
    var served = try serve_peer.listenArgs(&.{ paths.emulator, "serve", "--targets", cfg_path, "--listen", "tcp:127.0.0.1:0", serve_peer.image_path }, &line);
    defer served.child.kill(std.testing.io);

    var listing = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer listing.deinit();
    const gen_text = try std.fmt.allocPrint(gpa, "{d}", .{listing.parsed.value.array.items[0].object.get("generation").?.integer});
    defer gpa.free(gen_text);

    var flashed = try ctl_run.run(gpa, served.bound, &.{
        "targets", "flash", "bench", "jlink-a", "fpb-ra8e1", gen_text, "-", "--elf", elf_path, "--reset",
    });
    defer flashed.deinit();
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, flashed.term);
    try std.testing.expect(flashed.field("flash").object.get("verified").?.bool);
    try std.testing.expect(flashed.field("reset").object.get("reset").?.bool);

    var after = try ctl_run.run(gpa, served.bound, &.{ "targets", "list" });
    defer after.deinit();
    try std.testing.expect(!after.parsed.value.array.items[0].object.get("reserved").?.bool);
}
