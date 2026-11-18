//! Bounded in-memory ELF staging on a `probe-agent` peer connection before
//! SWD programming: enforces contiguous hex chunk assembly, size cap, and
//! SHA-256 verification before handing the buffer to `Registry.flash`.
const std = @import("std");

const host = @import("ra8_host");

const elf_image = host.jlink.elf_image;
const wire = host.probe_host.wire;

pub const Stage = struct {
    gpa: std.mem.Allocator = undefined,
    buffer: []u8 = &.{},
    got: usize = 0,
    sha256: [64]u8 = @splat(0),

    pub fn begin(self: *Stage, gpa: std.mem.Allocator, total_len: u32, sha256_hex: []const u8) !void {
        self.drop();
        if (total_len == 0 or total_len > wire.max_flash_elf) return error.InvalidElf;
        if (sha256_hex.len != 64) return error.BadChecksum;
        for (sha256_hex) |ch| {
            if (!std.ascii.isHex(ch)) return error.BadChecksum;
        }
        self.gpa = gpa;
        self.buffer = try gpa.alloc(u8, total_len);
        self.got = 0;
        for (sha256_hex, 0..) |ch, i| {
            self.sha256[i] = std.ascii.toLower(ch);
        }
    }

    pub fn chunk(self: *Stage, offset: u32, hex: []const u8) !void {
        if (self.buffer.len == 0 or offset != self.got) return error.InvalidElf;
        if (hex.len == 0 or hex.len % 2 != 0 or hex.len > wire.raw_chunk_bytes * 2) return error.InvalidElf;
        const raw_len = hex.len / 2;
        if (raw_len > self.buffer.len - self.got) return error.InvalidElf;
        _ = std.fmt.hexToBytes(self.buffer[self.got..][0..raw_len], hex) catch return error.InvalidElf;
        self.got += raw_len;
    }

    pub fn finish(self: *Stage) ![]u8 {
        if (self.buffer.len == 0 or self.got != self.buffer.len) return error.InvalidElf;
        const actual = elf_image.sha256Hex(self.buffer);
        if (!std.mem.eql(u8, &actual, &self.sha256)) {
            self.drop();
            return error.BadChecksum;
        }
        const out = self.buffer;
        self.buffer = &.{};
        self.got = 0;
        return out;
    }

    pub fn drop(self: *Stage) void {
        if (self.buffer.len != 0) self.gpa.free(self.buffer);
        self.buffer = &.{};
        self.got = 0;
        self.sha256 = @splat(0);
    }
};
