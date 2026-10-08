//! Running `ctl --connect SPEC --json` as a child and reading its answer,
//! shared by the ctl tests (RA8EMU-747, 757, 748).
const std = @import("std");
const test_paths = @import("test_paths");
const Term = std.process.Child.Term;
const Value = std.json.Value;

/// The UART fixture that prints `uart_irq_echo ready` (tests/fixtures/uart).
pub const uart_image = "tests/fixtures/uart/uart_irq_echo.elf";

/// One ctl run: its exit code and its stdout parsed as one JSON object.
pub const Answer = struct {
    term: Term,
    parsed: std.json.Parsed(Value),
    pub fn field(self: *const Answer, name: []const u8) Value {
        return self.parsed.value.object.get(name).?;
    }
    pub fn deinit(self: *Answer) void {
        self.parsed.deinit();
    }
};

pub fn run(gpa: std.mem.Allocator, spec: []const u8, words: []const []const u8) !Answer {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ test_paths.emulator, "ctl", "--connect", spec, "--json" });
    try argv.appendSlice(gpa, words);
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = argv.items });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const parsed = try std.json.parseFromSlice(Value, gpa, result.stdout, .{ .allocate = .alloc_always });
    return .{ .term = result.term, .parsed = parsed };
}

pub fn expectInteger(value: Value) !i64 {
    try std.testing.expect(value == .integer);
    return value.integer;
}

/// One ctl run's exit code and the UART text and last line its JSON lines carried.
pub const Stream = struct {
    term: Term,
    text: std.ArrayList(u8),
    last: std.ArrayList(u8),
    pub fn deinit(self: *Stream, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.last.deinit(gpa);
    }
};

pub fn stream(gpa: std.mem.Allocator, spec: []const u8, words: []const []const u8) !Stream {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ test_paths.emulator, "ctl", "--connect", spec, "--json" });
    try argv.appendSlice(gpa, words);
    const result = try std.process.run(gpa, std.testing.io, .{ .argv = argv.items });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var got: Stream = .{ .term = result.term, .text = .empty, .last = .empty };
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        got.last.clearRetainingCapacity();
        try got.last.appendSlice(gpa, line);
        const parsed = try std.json.parseFromSlice(Value, gpa, line, .{});
        defer parsed.deinit();
        const uart = parsed.value.object.get("uart") orelse continue;
        try got.text.appendSlice(gpa, uart.object.get("text").?.string);
    }
    return got;
}
