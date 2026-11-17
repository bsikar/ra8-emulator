//! A tiny owned ELF/symbol/DWARF image and its decoded instruction memory.
const std = @import("std");

const ra8 = @import("ra8");
const Builder = @import("symbol_image.zig").Builder;
const bus = ra8.chip.core.cpu.bus;

pub const golden =
    "0x00000100 <entry+0x0>: movs r0, #1 ; local value\n" ++
    "0x00000102 <entry+0x2>: movw r2, #0x5fa ; SCB.VECTKEY\n" ++
    "0x00000106 <entry+0x6>: b.w #0x110 ; callee\n" ++
    "0x0000010A <entry+0xa>: ldr r3, [sp, #4] ; local slot\n";

const abbrev = [_]u8{
    1,    0x11, 1, 3,    8, 0,    0,
    2,    0x2e, 1, 0x11, 1, 0x12, 6,
    0x40, 0x18, 0, 0,    4, 0x34, 0,
    3,    8,    2, 0x18, 0, 0,
};
const dies = [_]u8{
    1,    'a', '.',  'c', 0,
    2,    0,   1,    0,   0,
    0x10, 0,   0,    0,   1,
    0x5d, 4,   'v',  'a', 'l',
    'u',  'e', 0,    1,   0x50,
    4,    's', 'l',  'o', 't',
    0,    2,   0x91, 4,   0,
    0,
};

pub fn image(buffer: []u8) !ra8.session.symbols.Image {
    var info: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&info);
    try writer.writeInt(u32, 7 + dies.len, .little);
    try writer.writeInt(u16, 4, .little);
    try writer.writeInt(u32, 0, .little);
    try writer.writeByte(4);
    try writer.writeAll(&dies);
    const bytes = Builder.buildDebug(buffer, &.{ "entry", "callee" }, &.{ 0x100, 0x110 }, writer.buffered(), &abbrev, "");
    const table = std.mem.bytesAsValue(ra8.session.symbols.SectionHeader, buffer[Builder.sh_off + Builder.shent ..][0..Builder.shent]);
    const entry = std.mem.bytesAsValue(ra8.session.symbols.Symbol, buffer[table.sh_offset..][0..@sizeOf(ra8.session.symbols.Symbol)]);
    entry.st_info = ra8.session.symbols.symbol_type.func;
    entry.st_size = 0x10;
    return ra8.session.symbols.Image.init(bytes);
}

pub const Ram = struct {
    bytes: [32]u8 = @splat(0),
    base: u32 = 0x100,

    pub fn init() Ram {
        var result: Ram = .{};
        @memcpy(result.bytes[0..12], &[_]u8{ 1, 0x20, 0x40, 0xf2, 0xfa, 0x52, 0, 0xf0, 3, 0xb8, 1, 0x9b });
        return result;
    }

    pub fn view(self: *Ram) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    fn read(context: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Ram = @ptrCast(@alignCast(context));
        if (address < self.base or address - self.base > self.bytes.len) return error.Unmapped;
        const at = address - self.base;
        if (into.len > self.bytes.len - at) return error.Unmapped;
        @memcpy(into, self.bytes[at..][0..into.len]);
    }

    fn write(_: *anyopaque, _: u32, _: []const u8) bus.Error!void {
        return error.Unmapped;
    }
};
