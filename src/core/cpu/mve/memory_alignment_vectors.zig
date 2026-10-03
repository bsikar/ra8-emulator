//! Conformance vectors for the MemA alignment required by MVE memory
//! elements (DDI0553). Each family includes aligned and misaligned input.
const vector = @import("../conformance/vector.zig");
const alignment = @import("../alignment.zig");

pub const Access = struct { address: u32, size: u32 };
const V = vector.Vector(Access, bool);
const base: u32 = 0x2000_0000;

pub fn isAligned(access: Access) bool {
    alignment.memA(access.address, access.size) catch return false;
    return true;
}

pub const vectors = [_]V{
    .{ .encoding = "VLDRW.32", .name = "word load aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VLDRW.32", .name = "word load misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VSTRW.32", .name = "word store aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VSTRW.32", .name = "word store misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VLDRH.S32", .name = "widening halfword load aligned", .input = .{ .address = base, .size = 2 }, .expect = true },
    .{ .encoding = "VLDRH.S32", .name = "widening halfword load misaligned", .input = .{ .address = base + 1, .size = 2 }, .expect = false },
    .{ .encoding = "VSTRH.32", .name = "narrowing halfword store aligned", .input = .{ .address = base, .size = 2 }, .expect = true },
    .{ .encoding = "VSTRH.32", .name = "narrowing halfword store misaligned", .input = .{ .address = base + 1, .size = 2 }, .expect = false },
    .{ .encoding = "VLDRW.U32 gather", .name = "gather load aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VLDRW.U32 gather", .name = "gather load misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VSTRW.32 scatter", .name = "scatter store aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VSTRW.32 scatter", .name = "scatter store misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VLDRD.U64 gather", .name = "doubleword gather beat aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VLDRD.U64 gather", .name = "doubleword gather beat misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VSTRD.64 scatter", .name = "doubleword scatter beat aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VSTRD.64 scatter", .name = "doubleword scatter beat misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VLDRW.U32 vector base", .name = "vector-base load aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VLDRW.U32 vector base", .name = "vector-base load misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VSTRW.32 vector base", .name = "vector-base store aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VSTRW.32 vector base", .name = "vector-base store misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VLD20", .name = "interleaving word load aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VLD20", .name = "interleaving word load misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
    .{ .encoding = "VST20", .name = "interleaving word store aligned", .input = .{ .address = base, .size = 4 }, .expect = true },
    .{ .encoding = "VST20", .name = "interleaving word store misaligned", .input = .{ .address = base + 2, .size = 4 }, .expect = false },
};

pub const covered = vector.encodingsOf(Access, bool, &vectors);
