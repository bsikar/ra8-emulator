const builtin = @import("builtin");
const std = @import("std");

const commander = @import("ra8").host.jlink.commander;
const emu_list = @import("ra8").host.jlink.emu_list;

fn writeFakeTool(tmp: *std.testing.TmpDir, alloc: std.mem.Allocator) ![:0]u8 {
    const io = std.testing.io;
    if (builtin.os.tag == .windows) {
        const script =
            "@echo off\r\n" ++
            "if \"%~5\"==\"-CommandFile\" (\r\n" ++
            "  echo J-Link[0]: Connection: USB, Serial number: 1083322193, ProductName: J-Link-OB-RA4M2\r\n" ++
            "  exit /b 0\r\n" ++
            ")\r\n" ++
            "set \"dir=%~dp0\"\r\n" ++
            "echo %~6>>\"%dir%calls.log\"\r\n" ++
            ":next\r\n" ++
            "if \"%~2\"==\"\" goto last\r\n" ++
            "shift\r\n" ++
            "goto next\r\n" ++
            ":last\r\n" ++
            "type \"%~1\" >>\"%dir%scripts.log\"\r\n" ++
            "echo S/N: 1083322193\r\n" ++
            "echo E000ED00 = 410FD232 \r\n" ++
            "echo PC = 02000996, CycleCnt = 00000010\r\n" ++
            "echo SP(R13)= 22000610, MSP= 22000610\r\n" ++
            "exit /b 0\r\n";
        try tmp.dir.writeFile(io, .{ .sub_path = "fake_jlink.cmd", .data = script });
        return tmp.dir.realPathFileAlloc(io, "fake_jlink.cmd", alloc);
    }
    const script =
        "#!/bin/sh\n" ++
        "dir=$(dirname \"$0\")\n" ++
        "if [ \"$5\" = \"-CommandFile\" ]; then\n" ++
        "  printf 'J-Link[0]: Connection: USB, Serial number: 1083322193, ProductName: J-Link-OB-RA4M2\\n'\n" ++
        "  exit 0\n" ++
        "fi\n" ++
        "printf '%s\\n' \"$6\" >> \"$dir/calls.log\"\n" ++
        "eval \"last=\\${$#}\"\n" ++
        "cat \"$last\" >> \"$dir/scripts.log\"\n" ++
        "printf 'S/N: 1083322193\\nE000ED00 = 410FD232 \\nPC = 02000996, CycleCnt = 1\\nSP(R13)= 22000610\\n'\n";
    const file = try tmp.dir.createFile(io, "fake_jlink.sh", .{ .permissions = .fromMode(0o755) });
    defer file.close(io);
    try file.writeStreamingAll(io, script);
    return tmp.dir.realPathFileAlloc(io, "fake_jlink.sh", alloc);
}

test "commander selects by padded USB serial and refuses wrong CPUID before state change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    const program = try writeFakeTool(&tmp, alloc);
    defer alloc.free(program);
    const scratch = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(scratch);
    const tool: commander.Tool = .{ .program = program, .scratch = scratch, .timeout_ms = 5_000 };

    var seen: [4]emu_list.Probe = undefined;
    var text: [4096]u8 = undefined;
    const listed = try commander.list(io, tool, &seen, &text);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(@as(u64, 1083322193), listed[0].serial);

    try std.testing.expectError(
        error.WrongCore,
        commander.operate(io, tool, 1083322193, "Cortex-M33", 0x410FD214, .reset, &text),
    );
    const scripts_after_refuse = try tmp.dir.readFileAlloc(io, "scripts.log", alloc, .limited(4096));
    defer alloc.free(scripts_after_refuse);
    try std.testing.expect(std.mem.indexOf(u8, scripts_after_refuse, "\nr\n") == null);

    const outcome = try commander.operate(io, tool, 1083322193, "Cortex-M85", 0x410FD232, .registers, &text);
    try std.testing.expectEqual(@as(u32, 0x02000996), outcome.registers.?.pc);
    const calls = try tmp.dir.readFileAlloc(io, "calls.log", alloc, .limited(4096));
    defer alloc.free(calls);
    try std.testing.expect(std.mem.indexOf(u8, calls, "001083322193") != null);
}
