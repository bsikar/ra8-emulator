//! Standalone non-circular hashing, reflection, comptime field-classification
//! guards, and ordered positional stream digests for COMMON qualification.
//! Imports zero snapshot codecs so qualification never shares production bugs.
const std = @import("std");
const ra8 = @import("ra8");

pub const Digest = [16]u8;
pub const Position = ra8.session.history_position.Position;

fn WholeInt(comptime T: type) type {
    const info = @typeInfo(T).int;
    const bits = @max(8, (info.bits + 7) / 8 * 8);
    return @Int(info.signedness, bits);
}

pub const Hasher = struct {
    a: std.hash.Wyhash = .init(0x9e3779b97f4a7c15),
    b: std.hash.Wyhash = .init(0xc2b2ae3d27d4eb4f),

    pub fn raw(self: *Hasher, data: []const u8) void {
        self.a.update(data);
        self.b.update(data);
    }

    pub fn byte(self: *Hasher, v: u8) void {
        self.raw(&.{v});
    }

    pub fn boolean(self: *Hasher, v: bool) void {
        self.byte(@intFromBool(v));
    }

    pub fn int(self: *Hasher, v: anytype) void {
        const W = WholeInt(@TypeOf(v));
        const le = std.mem.nativeToLittle(W, v);
        self.raw(std.mem.asBytes(&le));
    }

    /// Reads every byte of `data` without consulting any dirty bitmap or
    /// touched tracker. SIMD zero-block framing keeps 64 MiB Debug scans fast
    /// while preserving exact sensitivity to any 1-bit flip or length change.
    pub fn bytes(self: *Hasher, data: []const u8) void {
        self.int(@as(u64, data.len));
        if (data.len < 256) {
            self.raw(data);
            return;
        }
        self.byte(0xa5);
        var i: usize = 0;
        var zero_blocks: u64 = 0;
        while (i + 32 <= data.len) : (i += 32) {
            const chunk: *const [32]u8 = data[i..][0..32];
            const vec: @Vector(32, u8) = chunk.*;
            if (@reduce(.Or, vec) == 0) {
                zero_blocks += 1;
            } else {
                if (zero_blocks != 0) {
                    self.byte(0);
                    self.int(zero_blocks);
                    zero_blocks = 0;
                }
                self.byte(1);
                self.raw(chunk);
            }
        }
        if (zero_blocks != 0) {
            self.byte(0);
            self.int(zero_blocks);
        }
        self.byte(2);
        self.raw(data[i..]);
    }

    pub fn auto(self: *Hasher, val: anytype) void {
        const T = @TypeOf(val);
        switch (@typeInfo(T)) {
            .int => self.int(val),
            .bool => self.boolean(val),
            .float => |f| {
                const Bits = @Int(.unsigned, f.bits);
                self.int(@as(Bits, @bitCast(val)));
            },
            .@"enum" => self.int(@backingInt(val)),
            .array => |arr| {
                if (arr.child == u8) self.bytes(&val) else for (val) |item| self.auto(item);
            },
            .vector => |vec| {
                const arr: [vec.len]vec.child = val;
                self.auto(arr);
            },
            .optional => if (val) |inner| {
                self.byte(1);
                self.auto(inner);
            } else self.byte(0),
            .@"struct" => |st| {
                if (st.layout == .@"packed") {
                    self.int(@as(st.backing_integer.?, @bitCast(val)));
                } else {
                    inline for (st.field_names) |name| self.auto(@field(val, name));
                }
            },
            .@"union" => |un| {
                const Tag = un.tag_type orelse @compileError("untagged union in oracle: " ++ @typeName(T));
                self.auto(@as(Tag, val));
                switch (val) {
                    inline else => |payload| self.auto(payload),
                }
            },
            .void => {},
            .error_set => self.bytes(@errorName(val)),
            else => @compileError("pointer or unsupported type in oracle: " ++ @typeName(T)),
        }
    }

    pub fn autoExcept(self: *Hasher, val: anytype, comptime skip: anytype) void {
        const T = @TypeOf(val);
        comptime if (!skipsResolve(T, skip)) @compileError("oracle skip path invalid for " ++ @typeName(T));
        inline for (@typeInfo(T).@"struct".field_names) |name| {
            if (comptime hasExact(name, skip)) continue;
            const sub = comptime subPaths(name, skip);
            if (sub.len == 0) {
                self.auto(@field(val, name));
            } else {
                self.walkSub(@field(val, name), sub);
            }
        }
    }

    fn walkSub(self: *Hasher, val: anytype, comptime skip: anytype) void {
        switch (@typeInfo(@TypeOf(val))) {
            .array => for (val) |item| self.walkSub(item, skip),
            .@"struct" => self.autoExcept(val, skip),
            else => @compileError("oracle dotted skip must traverse struct or array"),
        }
    }

    pub fn final(self: Hasher) Digest {
        var copy_a = self.a;
        var copy_b = self.b;
        var out: Digest = undefined;
        std.mem.writeInt(u64, out[0..8], copy_a.final(), .little);
        std.mem.writeInt(u64, out[8..16], copy_b.final(), .little);
        return out;
    }
};

fn hasExact(comptime name: []const u8, comptime list: anytype) bool {
    inline for (list) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn subPaths(comptime prefix: []const u8, comptime list: anytype) []const []const u8 {
    comptime {
        var matched: []const []const u8 = &.{};
        for (list) |entry| {
            if (entry.len > prefix.len + 1 and
                std.mem.startsWith(u8, entry, prefix) and
                entry[prefix.len] == '.')
            {
                matched = matched ++ &[_][]const u8{entry[prefix.len + 1 ..]};
            }
        }
        return matched;
    }
}

fn skipsResolve(comptime T: type, comptime skip: anytype) bool {
    @setEvalBranchQuota(200_000);
    inline for (skip) |path| {
        if (!pathExists(T, path)) return false;
    }
    return true;
}

fn pathExists(comptime T: type, comptime path: []const u8) bool {
    return switch (@typeInfo(T)) {
        .array => |arr| pathExists(arr.child, path),
        .@"struct" => blk: {
            if (std.mem.indexOfScalar(u8, path, '.')) |dot| {
                const head = path[0..dot];
                if (!@hasField(T, head)) break :blk false;
                break :blk pathExists(@FieldType(T, head), path[dot + 1 ..]);
            }
            break :blk @hasField(T, path);
        },
        else => false,
    };
}

/// Comptime guard proving every field of `T` is classified once, with reasons
/// for every excluded host/wiring/cache field.
pub fn classified(comptime T: type, comptime included: anytype, comptime excluded: anytype) bool {
    @setEvalBranchQuota(200_000);
    inline for (included) |name| if (!@hasField(T, name)) return false;
    inline for (excluded) |item| if (!@hasField(T, item.name) or item.reason.len == 0) return false;
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        var hits: usize = 0;
        inline for (included) |inc| if (std.mem.eql(u8, field_name, inc)) {
            hits += 1;
        };
        inline for (excluded) |exc| if (std.mem.eql(u8, field_name, exc.name)) {
            hits += 1;
        };
        if (hits != 1) return false;
    }
    return true;
}

/// Continuous ordered stream digest binding sequence, channel, Position,
/// virtual_ns, and raw payload or lossless P6 PPM frame bytes.
pub const Stream = struct {
    hasher: Hasher = .{},
    count: u64 = 0,

    pub fn append(self: *Stream, channel: u8, at: Position, ns: u64, payload: []const u8) void {
        self.hasher.int(self.count);
        self.hasher.byte(channel);
        self.hasher.auto(at);
        self.hasher.int(ns);
        self.hasher.bytes(payload);
        self.count += 1;
    }

    pub fn frame(self: *Stream, allocator: std.mem.Allocator, at: Position, image: ra8.session.display.Frame) !void {
        const ppm = try image.ppm(allocator);
        defer allocator.free(ppm);
        self.append(2, at, image.virtual_ns, ppm);
    }

    pub fn rawFrame(self: *Stream, at: Position, ns: u64, width: u32, height: u32, pixels: []const u8) void {
        self.hasher.int(self.count);
        self.hasher.byte(3);
        self.hasher.auto(at);
        self.hasher.int(ns);
        self.hasher.int(width);
        self.hasher.int(height);
        self.hasher.bytes(pixels);
        self.count += 1;
    }

    pub fn digest(self: Stream) Digest {
        var copy = self.hasher;
        copy.int(self.count);
        return copy.final();
    }
};
