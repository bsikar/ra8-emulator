const std = @import("std");
const ra8 = @import("ra8");
const fixture = @import("fixture.zig");

test "scripted initialize attach break step stack scopes variables continue pause disconnect" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    try fixture.connect(&f.adapter);
    try fixture.expectSend(&f.adapter,
        \\{"seq":4,"type":"request","command":"threads"}
    , "\"name\":\"CPU0\"");
    try fixture.expectSend(&f.adapter,
        \\{"seq":5,"type":"request","command":"stepIn","arguments":{"threadId":1,"granularity":"instruction"}}
    , "\"success\":true");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.adapter.pump(&out.writer);
    try std.testing.expectEqual(@as(u32, 10), f.cpu.regs.pc);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"reason\":\"step\"") != null);
    try fixture.expectSend(&f.adapter,
        \\{"seq":6,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
    , "\"instructionPointerReference\":\"0x0000000A\"");
    try fixture.expectSend(&f.adapter,
        \\{"seq":7,"type":"request","command":"setInstructionBreakpoints","arguments":{"breakpoints":[{"instructionReference":"0x0c"}]}}
    , "\"verified\":true");
    try fixture.expectSend(&f.adapter,
        \\{"seq":8,"type":"request","command":"continue","arguments":{"threadId":1}}
    , "\"allThreadsContinued\":true");
    try f.adapter.pump(&out.writer);
    try std.testing.expectEqual(@as(u32, 12), f.cpu.regs.pc);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"reason\":\"instruction breakpoint\"") != null);
    try std.testing.expect(f.adapter.pending == null);
    try fixture.expectSend(&f.adapter,
        \\{"seq":9,"type":"request","command":"continue","arguments":{"threadId":1}}
    , "\"success\":true");
    try f.adapter.pump(&out.writer);
    // Resume grace runs the instruction stopped on, then the break can hit again.
    try fixture.expectSend(&f.adapter,
        \\{"seq":10,"type":"request","command":"pause","arguments":{"threadId":1}}
    , "\"reason\":\"pause\"");
    try fixture.expectSend(&f.adapter,
        \\{"seq":11,"type":"request","command":"disconnect"}
    , "\"event\":\"terminated\"");
    try std.testing.expect(f.adapter.closed);
}

test "running loop accepts pause and rejects stopped-only inspection" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    try fixture.connect(&f.adapter);
    try fixture.expectSend(&f.adapter,
        \\{"seq":4,"type":"request","command":"continue","arguments":{"threadId":1}}
    , "\"success\":true");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.adapter.pump(&out.writer);
    try std.testing.expect(f.adapter.pending != null);
    try fixture.expectSend(&f.adapter,
        \\{"seq":5,"type":"request","command":"stackTrace","arguments":{"threadId":1}}
    , "notStopped");
    try fixture.expectSend(&f.adapter,
        \\{"seq":6,"type":"request","command":"pause","arguments":{"threadId":1}}
    , "\"reason\":\"pause\"");
    try std.testing.expect(f.adapter.pending == null);
    try std.testing.expectEqual(ra8.session.stop_machine.Mode.halted, f.machine.mode);
}

test "invalid lifecycle unknown commands malformed JSON and invalid thread are explicit errors" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    try fixture.expectSend(&f.adapter,
        \\{"seq":1,"type":"request","command":"threads"}
    , "InvalidState");
    try fixture.connect(&f.adapter);
    try fixture.expectSend(&f.adapter,
        \\{"seq":4,"type":"request","command":"evaluate"}
    , "UnsupportedRequest");
    try fixture.expectSend(&f.adapter,
        \\{"seq":5,"type":"request","command":"stepIn","arguments":{"threadId":3}}
    , "UnknownThread");
    var out: [100]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&out);
    try std.testing.expectError(error.UnexpectedEndOfInput, f.adapter.request("{", &writer));
}

test "launch invokes application loader and defers running until configurationDone" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    const Loader = struct {
        fn open(ctx: *anyopaque, path: []const u8) !ra8.dap.adapter.Target {
            const target: *fixture.Fixture = @ptrCast(@alignCast(ctx));
            try std.testing.expectEqualStrings("firmware.elf", path);
            return .{ .session = &target.session };
        }
    };
    f.adapter.target = null;
    f.adapter.opener = .{ .context = &f, .openFn = Loader.open };
    try fixture.expectSend(&f.adapter,
        \\{"seq":1,"type":"request","command":"initialize"}
    , "\"success\":true");
    try fixture.expectSend(&f.adapter,
        \\{"seq":2,"type":"request","command":"launch","arguments":{"program":"firmware.elf","stopOnEntry":false}}
    , "\"event\":\"initialized\"");
    try std.testing.expect(f.adapter.pending == null);
    try fixture.expectSend(&f.adapter,
        \\{"seq":3,"type":"request","command":"configurationDone"}
    , "\"success\":true");
    try std.testing.expect(f.adapter.pending != null);
}

test "implicit and explicit statement stepping refuse without advancing the machine" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    try fixture.connect(&f.adapter);
    for ([_][]const u8{ "stepIn", "next", "stepOut" }) |command| {
        for ([_][]const u8{ "", ",\"granularity\":\"statement\"" }) |granularity| {
            const request = try std.fmt.allocPrint(
                std.testing.allocator,
                "{{\"seq\":4,\"type\":\"request\",\"command\":\"{s}\",\"arguments\":{{\"threadId\":1{s}}}}}",
                .{ command, granularity },
            );
            defer std.testing.allocator.free(request);
            try fixture.expectSend(&f.adapter, request, "UnsupportedGranularity");
            try std.testing.expect(f.adapter.pending == null);
            try std.testing.expectEqual(@as(u32, 8), f.cpu.regs.pc);
        }
    }
}

test "next preserves the Session call target across multiple bounded slices" {
    var f: fixture.Fixture = .{};
    try f.init();
    defer f.deinit();
    // bl 0x10; b .; padding; subs r0,1; bne 0x10; bx lr.
    f.bytes[8..22].* = .{ 0, 0xf0, 2, 0xf8, 0xfe, 0xe7, 0, 0xbf, 1, 0x38, 0xfd, 0xd1, 0x70, 0x47 };
    try f.session.setRegister(.cpu0, .r0, 30_000);
    try fixture.connect(&f.adapter);
    try fixture.expectSend(&f.adapter,
        \\{"seq":4,"type":"request","command":"next","arguments":{"threadId":1,"granularity":"instruction"}}
    , "\"success\":true");
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.adapter.pump(&out.writer);
    try std.testing.expect(f.adapter.pending != null);
    for (0..10) |_| {
        if (f.adapter.pending == null) break;
        try f.adapter.pump(&out.writer);
    }
    try std.testing.expect(f.adapter.pending == null);
    try std.testing.expectEqual(@as(u32, 12), f.cpu.regs.pc);
    try std.testing.expectEqual(@as(u32, 0), try f.session.register(.cpu0, .r0));
    try std.testing.expectEqual(@as(u64, 100), f.session.live.budget);
}
