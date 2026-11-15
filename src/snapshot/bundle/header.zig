//! Strict regular-file subset of USTAR; never interpret links or extension headers.
const std = @import("std");

pub const Header = struct {
    raw: [@sizeOf(std.tar.Writer.Header)]u8,

    pub fn read(input: *std.Io.Reader) !Header {
        var self: Header = undefined;
        try input.readSliceAll(&self.raw);
        if (self.zero()) return self;
        const bytes = &self.raw;
        var sum: u64 = 0;
        for (bytes, 0..) |byte, index| {
            sum += if (index >= 148 and index < 156) @as(u8, ' ') else byte;
        }
        if (sum != try octal(self.raw[148..156])) return error.BadChecksum;
        if (!std.mem.eql(u8, self.raw[257..263], "ustar\x00") or
            !std.mem.eql(u8, self.raw[263..265], "00")) return error.BadTarFormat;
        if (self.raw[156] != '0') return error.UnsupportedEntry;
        if ((try field(self.raw[157..257])).len != 0) return error.UnsupportedEntry;
        return self;
    }

    pub fn zero(self: *const Header) bool {
        return std.mem.allEqual(u8, &self.raw, 0);
    }

    pub fn path(self: *const Header, buffer: []u8) ![]const u8 {
        const name = try field(self.raw[0..100]);
        const prefix = try field(self.raw[345..500]);
        if (prefix.len == 0) return std.fmt.bufPrint(buffer, "{s}", .{name});
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ prefix, name });
    }

    pub fn size(self: *const Header) !u64 {
        return octal(self.raw[124..136]);
    }
};

fn field(bytes: []const u8) ![]const u8 {
    const end = std.mem.findScalar(u8, bytes, 0) orelse return bytes;
    if (!std.mem.allEqual(u8, bytes[end..], 0)) return error.BadTarField;
    return bytes[0..end];
}

fn octal(bytes: []const u8) !u64 {
    const value = std.mem.trim(u8, bytes, " \x00");
    if (value.len == 0) return 0;
    return std.fmt.parseInt(u64, value, 8) catch error.BadTarNumber;
}
