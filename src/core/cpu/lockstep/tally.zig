//! The per-class divergence table a lockstep run ends with, and every core
//! slice puts in its PR body.
//!
//! A class is an instruction group's `op.Group.name`, so the rows line up with
//! the files under src/core/cpu/ops/. Each instruction lands in exactly one
//! column: matched, diverged, or skipped because Unicorn cannot be the oracle
//! for it (the Armv8.1-M encodings it does not implement).
const std = @import("std");

pub const Outcome = enum { matched, diverged, skipped };

pub const Row = struct {
    class: []const u8,
    matched: u64 = 0,
    diverged: u64 = 0,
    skipped: u64 = 0,

    pub fn total(self: Row) u64 {
        return self.matched + self.diverged + self.skipped;
    }
};

pub const Tally = struct {
    rows: std.ArrayListUnmanaged(Row) = .empty,

    pub fn deinit(self: *Tally, gpa: std.mem.Allocator) void {
        self.rows.deinit(gpa);
    }

    /// Count one instruction. `class` must outlive the tally; group names are
    /// string literals, so they do.
    pub fn record(self: *Tally, gpa: std.mem.Allocator, class: []const u8, outcome: Outcome) !void {
        const row = try self.rowFor(gpa, class);
        switch (outcome) {
            .matched => row.matched += 1,
            .diverged => row.diverged += 1,
            .skipped => row.skipped += 1,
        }
    }

    pub fn find(self: *const Tally, class: []const u8) ?Row {
        for (self.rows.items) |row| {
            if (std.mem.eql(u8, row.class, class)) return row;
        }
        return null;
    }

    pub fn sum(self: *const Tally) Row {
        var whole: Row = .{ .class = "total" };
        for (self.rows.items) |row| {
            whole.matched += row.matched;
            whole.diverged += row.diverged;
            whole.skipped += row.skipped;
        }
        return whole;
    }

    /// A Markdown table, one row per class in first-seen order, then a total.
    pub fn writeTable(self: *const Tally, out: anytype) !void {
        try out.writeAll("| class | matched | diverged | skipped |\n");
        try out.writeAll("|---|---:|---:|---:|\n");
        for (self.rows.items) |row| try writeRow(out, row);
        try writeRow(out, self.sum());
    }

    fn rowFor(self: *Tally, gpa: std.mem.Allocator, class: []const u8) !*Row {
        for (self.rows.items) |*row| {
            if (std.mem.eql(u8, row.class, class)) return row;
        }
        try self.rows.append(gpa, .{ .class = class });
        return &self.rows.items[self.rows.items.len - 1];
    }
};

fn writeRow(out: anytype, row: Row) !void {
    try out.print("| {s} | {d} | {d} | {d} |\n", .{
        row.class, row.matched, row.diverged, row.skipped,
    });
}
