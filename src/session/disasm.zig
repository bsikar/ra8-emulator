//! One instruction, in text, for the fault path and the debugger.
//!
//! When a run ends on a fault the PC alone is not much of an answer. Give this
//! the bytes at the PC and it gives back "str r1, [r0]", decoded by the Zig
//! core's own table and printed by its group printers (RA8EMU-17), in the
//! spelling the parity digest tests pin. No C is involved (RA8EMU-249).
const annotate = @import("annotate.zig");
const annotation_literal = @import("annotation_literal.zig");

const core_view = @import("core_view.zig");
const Instr = @import("ra8_chip").core.cpu.instr.Instr;
const printers = @import("ra8_chip").core.cpu.text.disasm;
const std = @import("std");
const symbols = @import("symbols.zig");
const text = @import("ra8_chip").core.cpu.text.text;

pub const Error = error{NothingDecoded};

pub const Text = text.Text;

/// Decode the single instruction at `address` from `bytes`: two bytes for a
/// 16-bit encoding, four for a 32-bit one, little-endian halfwords.
pub fn one(address: u32, bytes: []const u8) Error!Text {
    const instr = fromBytes(address, bytes) orelse return Error.NothingDecoded;
    return printers.one(instr) orelse Error.NothingDecoded;
}

fn fromBytes(address: u32, bytes: []const u8) ?Instr {
    if (bytes.len < 2) return null;
    const hw1 = halfword(bytes[0..2]);
    if (!Instr.isWide(hw1)) return .{ .address = address, .hw1 = hw1, .size = 2 };
    if (bytes.len < 4) return null;
    return .{ .address = address, .hw1 = hw1, .hw2 = halfword(bytes[2..4]), .size = 4 };
}

fn halfword(pair: *const [2]u8) u16 {
    return @as(u16, pair[0]) | (@as(u16, pair[1]) << 8);
}

pub const max_rows = 64;
pub const Row = struct {
    address: u32,
    size: u32 = 2,
    bytes: [4]u8 = @splat(0),
    text: Text = .{},
    function: []const u8 = "",
    offset: u32 = 0,
};

/// The embedding/pane API: bounded rows, read from this core's current memory.
/// Instruction bytes remain available even when a decoder does not know them.
pub fn capture(core: core_view.View, image: ?symbols.Image, start: u32, into: []Row) !u32 {
    if (into.len > max_rows or start & 1 != 0) return error.BadDisassemblyRange;
    var address = start;
    for (into) |*row| {
        row.* = read(core, image, address);
        address = std.math.add(u32, address, row.size) catch return error.BadDisassemblyRange;
    }
    return address;
}

/// Append symbol, DWARF local, and literal annotations to an already-decoded disassembly `into` buffer.
pub fn annotateLine(core: ?core_view.View, image: ?symbols.Image, address: u32, bytes: []const u8, into: *Text) void {
    annotate.at(image, address, into);
    const live_core = core orelse return;
    const instr = fromBytes(address, bytes) orelse return;
    annotation_literal.append(live_core, instr, into);
}

pub fn read(core: core_view.View, image: ?symbols.Image, address: u32) Row {
    var row: Row = .{ .address = address };
    function(image, &row);
    core.read(address, row.bytes[0..2]) catch {
        row.text.put("<unreadable>", .{});
        return row;
    };
    const first = halfword(row.bytes[0..2]);
    if (Instr.isWide(first)) {
        row.size = 4;
        core.read(address +% 2, row.bytes[2..4]) catch {
            row.text.put("<unreadable>", .{});
            return row;
        };
    }
    row.text = one(address, row.bytes[0..row.size]) catch {
        row.text.put("<undecoded 0x{X:0>4}>", .{first});
        return row;
    };
    annotateLine(core, image, address, row.bytes[0..row.size], &row.text);
    return row;
}

fn function(image: ?symbols.Image, row: *Row) void {
    const loaded = image orelse return;
    if (symbols.inside(loaded, row.address)) |site| {
        row.function = site.name;
        row.offset = site.offset;
    } else if (annotate.symbolAt(loaded, row.address)) |name| {
        row.function = name;
    }
}

/// One canonical backend/CLI line. Callers keep structured Row fields as well.
pub fn write(row: Row, writer: *std.Io.Writer) !void {
    try writer.print("0x{X:0>8}", .{row.address});
    if (row.function.len != 0) {
        try writer.print(" <{s}+0x{x}>", .{ row.function, row.offset });
    }
    try writer.print(": {s}\n", .{row.text.slice()});
}
