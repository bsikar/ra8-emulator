//! RA8EMU-325: walks every executable PT_LOAD segment of each ELF named on the
//! command line, compares the Zig core's disassembly with Capstone's one
//! instruction at a time, and prints a match table by decode group. Exits 1
//! on any mismatch.
//!
//! Not compared, only counted: encodings our decode leaves unclaimed (literal
//! pools, data, UNPREDICTABLE forms) and groups with no printer yet (the
//! Armv8.1-M ones, RA8EMU-256). The walk is a linear sweep, so a literal pool
//! can desync it for a few halfwords; every comparison stays valid because
//! each instruction is decoded on its own.
const std = @import("std");
const ra8 = @import("ra8");
const decode = ra8.core.cpu.decode;
const Instr = ra8.core.cpu.instr.Instr;
const capstone = ra8.core.disasm;

/// Mismatches printed in full before the rest are only counted.
pub const shown_limit: usize = 20;

pub const Row = struct { matched: usize = 0, mismatched: usize = 0 };

pub const Tally = struct {
    rows: std.StringArrayHashMap(Row),
    unclaimed: usize = 0,
    unprinted: usize = 0,
    shown: usize = 0,

    pub fn init(gpa: std.mem.Allocator) Tally {
        return .{ .rows = std.StringArrayHashMap(Row).init(gpa) };
    }

    pub fn deinit(self: *Tally) void {
        self.rows.deinit();
    }

    pub fn total(self: *const Tally) Row {
        var sum: Row = .{};
        for (self.rows.values()) |row| {
            sum.matched += row.matched;
            sum.mismatched += row.mismatched;
        }
        return sum;
    }
};

/// Sweeps `bytes`, loaded at `base`, and tallies every instruction. A wide
/// first halfword with no second one left ends the sweep.
pub fn walk(tally: *Tally, base: u32, bytes: []const u8, log: anytype) !void {
    var at: usize = 0;
    while (at + 2 <= bytes.len) {
        const hw1 = std.mem.readInt(u16, bytes[at..][0..2], .little);
        const size: u32 = if (Instr.isWide(hw1)) 4 else 2;
        if (at + size > bytes.len) return;
        const hw2: u16 = if (size == 4) std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little) else 0;
        const instr: Instr = .{ .address = base + @as(u32, @intCast(at)), .hw1 = hw1, .hw2 = hw2, .size = size };
        try compare(tally, instr, bytes[at..][0..size], log);
        at += size;
    }
}

fn compare(tally: *Tally, instr: Instr, raw: []const u8, log: anytype) !void {
    const hit = decode.decode(instr) orelse {
        tally.unclaimed += 1;
        return;
    };
    const ours = decode.text.disasm.one(instr) orelse {
        tally.unprinted += 1;
        return;
    };
    const row = try tally.rows.getOrPutValue(hit.group, .{});
    const theirs = capstone.one(instr.address, raw) catch null;
    if (theirs) |t| {
        if (std.mem.eql(u8, ours.slice(), t.slice())) {
            row.value_ptr.matched += 1;
            return;
        }
    }
    row.value_ptr.mismatched += 1;
    if (tally.shown >= shown_limit) return;
    tally.shown += 1;
    const their_text = if (theirs) |t| t.slice() else "<invalid>";
    try log.print("0x{x:0>8} {x:0>4} {x:0>4} [{s}]: ours \"{s}\", capstone \"{s}\"\n", .{ instr.address, instr.hw1, instr.hw2, hit.group, ours.slice(), their_text });
}

/// The match table as Markdown, one row per group in first-seen order.
pub fn report(tally: *const Tally, out: anytype) !void {
    try out.writeAll("| group | matched | mismatched |\n|---|---:|---:|\n");
    for (tally.rows.keys(), tally.rows.values()) |group, row| {
        try out.print("| {s} | {d} | {d} |\n", .{ group, row.matched, row.mismatched });
    }
    const sum = tally.total();
    try out.print("| total | {d} | {d} |\n", .{ sum.matched, sum.mismatched });
    try out.print("\nnot compared: {d} unclaimed by our decode, {d} in groups with no printer yet\n", .{ tally.unclaimed, tally.unprinted });
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    var tally = Tally.init(gpa);
    defer tally.deinit();
    const log = std.io.getStdErr().writer();
    for (args[1..]) |path| try walkFile(gpa, &tally, path, log);
    try report(&tally, std.io.getStdOut().writer());
    if (tally.total().mismatched != 0) std.process.exit(1);
}

fn walkFile(gpa: std.mem.Allocator, tally: *Tally, path: []const u8, log: anytype) !void {
    const bytes = try std.fs.cwd().readFileAlloc(gpa, path, 64 << 20);
    defer gpa.free(bytes);
    const image = try ra8.core.elf.Image.init(bytes);
    var index: u16 = 0;
    while (index < image.segmentCount()) : (index += 1) {
        const segment = image.loadSegment(index) orelse continue;
        if (!segment.executable()) continue;
        try walk(tally, segment.vaddr, segment.bytes, log);
    }
}
