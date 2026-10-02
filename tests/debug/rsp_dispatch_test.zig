//! The read side of the remote protocol, against a live engine: halt
//! reason, qSupported, registers in target.xml order, and memory.
const std = @import("std");
const ra8 = @import("ra8");
const dispatch = ra8.core.rsp_dispatch;
const memmap = ra8.core.memmap;
const Engine = ra8.core.engine.Engine;

const base: u32 = memmap.sram_base;

fn open() !Engine {
    var core = try Engine.open();
    errdefer core.close();
    try core.mapBoardRam();
    try core.write(base, &[_]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02 });
    try core.setRegister(.r0, 0x1122_3344);
    try core.setRegister(.r12, 0xc);
    try core.setRegister(.sp, base + 0x1f00);
    try core.setRegister(.pc, base + 0x18);
    return core;
}

test "the halt reason, qSupported and qAttached" {
    var core = try open();
    defer core.close();
    const stub = dispatch.Dispatch{ .core = &core };
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("S05", try stub.answer("?", &out));
    try std.testing.expectEqualStrings("PacketSize=1000;qXfer:features:read+", try stub.answer("qSupported:multiprocess+;swbreak+", &out));
    try std.testing.expectEqualStrings("1", try stub.answer("qAttached", &out));
    try std.testing.expectEqualStrings("OK", try stub.answer("Hg0", &out));
}

test "an unknown request gets the empty reply" {
    var core = try open();
    defer core.close();
    const stub = dispatch.Dispatch{ .core = &core };
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("", try stub.answer("vMustReplyEmpty", &out));
    try std.testing.expectEqualStrings("", try stub.answer("", &out));
}

// Words go out little-endian: r0 = 0x11223344 reads as 44332211.
test "g is seventeen little-endian words in target.xml order" {
    var core = try open();
    defer core.close();
    const stub = dispatch.Dispatch{ .core = &core };
    var out: [256]u8 = undefined;
    const all = try stub.answer("g", &out);
    try std.testing.expectEqual(@as(usize, 17 * 8), all.len);
    try std.testing.expectEqualStrings("44332211", all[0..8]);
    try std.testing.expectEqualStrings("0c000000", all[12 * 8 .. 13 * 8]);
    try std.testing.expectEqualStrings("001f0022", all[13 * 8 .. 14 * 8]);
    try std.testing.expectEqualStrings("18000022", all[15 * 8 .. 16 * 8]);
}

test "p reads one register by its target.xml number" {
    var core = try open();
    defer core.close();
    const stub = dispatch.Dispatch{ .core = &core };
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("18000022", try stub.answer("pf", &out));
    try std.testing.expectEqualStrings("44332211", try stub.answer("p0", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("p11", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("pzz", &out));
}

test "m reads memory as hex, and an unmapped span is E01" {
    var core = try open();
    defer core.close();
    const stub = dispatch.Dispatch{ .core = &core };
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("deadbeef0102", try stub.answer("m22000000,6", &out));
    try std.testing.expectEqualStrings("E01", try stub.answer("m10,4", &out));
    try std.testing.expectEqualStrings("E00", try stub.answer("m22000000", &out));
}

test "an m reply that would not fit says so" {
    var core = try open();
    defer core.close();
    const stub = dispatch.Dispatch{ .core = &core };
    var out: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpace, stub.answer("m22000000,40", &out));
}
