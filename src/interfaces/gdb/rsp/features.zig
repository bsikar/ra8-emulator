//! The target description gdb asks for with
//! `qXfer:features:read:target.xml:offset,length`, and the slicing that
//! answers it a window at a time.
//!
//! The registers are the M-profile core feature in gdb's own order: r0 to
//! r12, sp, lr, pc, then xpsr. They are numbered in sequence, so xpsr is
//! register 16 and the `g` reply is seventeen little-endian words.
//! `<architecture>` comes from the inspected core's `machine.Core` descriptor:
//! `armv8.1-m.main` when `core.profile.v8_1m`, `armv8-m.main` otherwise, with
//! no MVE register group on M33.
const Core = @import("ra8_chip").core.machine.Core;
const std = @import("std");

pub const Error = error{NoSpace};

const core_feature =
    \\<feature name="org.gnu.gdb.arm.m-profile">
    \\<reg name="r0" bitsize="32"/>
    \\<reg name="r1" bitsize="32"/>
    \\<reg name="r2" bitsize="32"/>
    \\<reg name="r3" bitsize="32"/>
    \\<reg name="r4" bitsize="32"/>
    \\<reg name="r5" bitsize="32"/>
    \\<reg name="r6" bitsize="32"/>
    \\<reg name="r7" bitsize="32"/>
    \\<reg name="r8" bitsize="32"/>
    \\<reg name="r9" bitsize="32"/>
    \\<reg name="r10" bitsize="32"/>
    \\<reg name="r11" bitsize="32"/>
    \\<reg name="r12" bitsize="32"/>
    \\<reg name="sp" bitsize="32" type="data_ptr"/>
    \\<reg name="lr" bitsize="32"/>
    \\<reg name="pc" bitsize="32" type="code_ptr"/>
    \\<reg name="xpsr" bitsize="32"/>
    \\</feature>
    \\</target>
    \\
;

const xml_head =
    \\<?xml version="1.0"?>
    \\<!DOCTYPE target SYSTEM "gdb-target.dtd">
    \\<target version="1.0">
    \\
;

pub const target_xml = xml_head ++ "<architecture>armv8.1-m.main</architecture>\n" ++ core_feature;

pub const target_xml_v8m = xml_head ++ "<architecture>armv8-m.main</architecture>\n" ++ core_feature;

pub fn xmlFor(core: ?Core) []const u8 {
    const info = core orelse return target_xml;
    return if (info.profile.v8_1m) target_xml else target_xml_v8m;
}

/// Answers one `qXfer:features:read:` request for the default v8.1-M target.
pub fn read(args: []const u8, out: []u8) Error![]const u8 {
    return readFor(null, args, out);
}

/// Answers one `qXfer:features:read:` request for `core`. `args` is what
/// follows that prefix: `annex:offset,length`. The reply is `m` and a window
/// when more remains, `l` and the last window when it does not, or `E00` when
/// the annex is not ours or the numbers do not parse.
pub fn readFor(core: ?Core, args: []const u8, out: []u8) Error![]const u8 {
    const window = parse(args) orelse return copy(out, "E00");
    const doc = xmlFor(core);
    const from = @min(window.offset, doc.len);
    const to = @min(doc.len, from + window.length);
    const marker: u8 = if (to < doc.len) 'm' else 'l';
    const chunk = doc[from..to];
    if (out.len < chunk.len + 1) return error.NoSpace;
    out[0] = marker;
    @memcpy(out[1 .. chunk.len + 1], chunk);
    return out[0 .. chunk.len + 1];
}

const Window = struct { offset: usize, length: usize };

fn parse(args: []const u8) ?Window {
    const colon = std.mem.indexOfScalar(u8, args, ':') orelse return null;
    if (!std.mem.eql(u8, args[0..colon], "target.xml")) return null;
    const numbers = args[colon + 1 ..];
    const comma = std.mem.indexOfScalar(u8, numbers, ',') orelse return null;
    const offset = std.fmt.parseInt(usize, numbers[0..comma], 16) catch return null;
    const length = std.fmt.parseInt(usize, numbers[comma + 1 ..], 16) catch return null;
    return .{ .offset = offset, .length = length };
}

fn copy(out: []u8, text: []const u8) Error![]const u8 {
    if (out.len < text.len) return error.NoSpace;
    @memcpy(out[0..text.len], text);
    return out[0..text.len];
}
