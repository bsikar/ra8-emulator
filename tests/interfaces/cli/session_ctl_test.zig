//! `ctl --connect ... --json` against a spawned `serve --listen` on a temp
//! Unix path (RA8EMU-747): each command's JSON shape, a refusal, and the
//! usage refusal.
const std = @import("std");
const ra8 = @import("ra8");
const test_paths = @import("test_paths");
const serve_peer = @import("serve_peer.zig");
const ctl = ra8.core.session_ctl;
const Term = std.process.Child.Term;
const Value = std.json.Value;

/// One ctl run: its exit code and its stdout parsed as one JSON object.
const Answer = struct {
    term: Term,
    parsed: std.json.Parsed(Value),
    fn field(self: *const Answer, name: []const u8) Value {
        return self.parsed.value.object.get(name).?;
    }
    fn deinit(self: *Answer) void {
        self.parsed.deinit();
    }
};

fn run(gpa: std.mem.Allocator, spec: []const u8, words: []const []const u8) !Answer {
    var argv = std.ArrayList([]const u8).init(gpa);
    defer argv.deinit();
    try argv.appendSlice(&.{ test_paths.emulator, "ctl", "--connect", spec, "--json" });
    try argv.appendSlice(words);
    const result = try std.process.Child.run(.{ .allocator = gpa, .argv = argv.items });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const parsed = try std.json.parseFromSlice(Value, gpa, result.stdout, .{ .allocate = .alloc_always });
    return .{ .term = result.term, .parsed = parsed };
}

fn expectInteger(value: Value) !i64 {
    try std.testing.expect(value == .integer);
    return value.integer;
}

test "ctl --json drives load, run, step, pause, regs and mem against a running serve" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/ctl.sock", .{tmp.sub_path});
    defer gpa.free(path);
    const spec = try std.fmt.allocPrint(gpa, "unix:{s}", .{path});
    defer gpa.free(spec);
    var line: [256]u8 = undefined;
    var served = try serve_peer.listen(gpa, spec, &line);
    defer _ = served.child.kill() catch {};

    var loaded = try run(gpa, spec, &.{ "load", serve_peer.image_path });
    defer loaded.deinit();
    try std.testing.expectEqual(Term{ .Exited = 0 }, loaded.term);
    try std.testing.expectEqualStrings(serve_peer.image_path, loaded.field("loaded").string);
    try std.testing.expect(try expectInteger(loaded.field("bytes")) > 0);

    // A step straight after the load runs one instruction from reset; the
    // fixture may end in a fault once it has run to completion.
    var stepped = try run(gpa, spec, &.{"step"});
    defer stepped.deinit();
    try std.testing.expectEqualStrings("stepped", stepped.field("stopped").object.get("reason").?.string);
    // Where the first step landed is code, so it is mapped for the read below.
    const code = try expectInteger(stepped.field("stopped").object.get("pc").?);

    var ran = try run(gpa, spec, &.{ "run", "--budget", "1000" });
    defer ran.deinit();
    const stop = ran.field("stopped").object;
    try std.testing.expectEqualStrings("cpu0", stop.get("core").?.string);
    try std.testing.expect(stop.get("reason").? == .string);
    try std.testing.expect(try expectInteger(stop.get("pc").?) != 0);
    _ = try expectInteger(stop.get("detail").?);

    var paused = try run(gpa, spec, &.{"pause"});
    defer paused.deinit();
    try std.testing.expect(paused.field("paused").bool);

    var all = try run(gpa, spec, &.{"regs"});
    defer all.deinit();
    const registers = all.field("registers").object;
    try std.testing.expectEqual(@as(usize, 17), registers.count());
    const pc = try expectInteger(registers.get("pc").?);

    var two = try run(gpa, spec, &.{ "regs", "pc", "sp" });
    defer two.deinit();
    try std.testing.expectEqual(@as(usize, 2), two.field("registers").object.count());
    try std.testing.expectEqual(pc, try expectInteger(two.field("registers").object.get("pc").?));

    const at = try std.fmt.allocPrint(gpa, "{d}", .{code});
    defer gpa.free(at);
    var memory = try run(gpa, spec, &.{ "mem", at, "4" });
    defer memory.deinit();
    try std.testing.expectEqual(Term{ .Exited = 0 }, memory.term);
    try std.testing.expectEqual(code, try expectInteger(memory.field("address")));
    try std.testing.expectEqual(@as(i64, 4), try expectInteger(memory.field("length")));
    try std.testing.expectEqual(@as(usize, 8), memory.field("hex").string.len);

    var refused = try run(gpa, spec, &.{ "mem", "0", "0x200000" });
    defer refused.deinit();
    try std.testing.expectEqual(Term{ .Exited = 1 }, refused.term);
    try std.testing.expectEqualStrings("Refused", refused.field("error").string);
    try std.testing.expectEqual(@as(i64, ra8.interfaces.rpc.server.app_codes.too_long), try expectInteger(refused.field("code")));
}

test "ctl with a bad command prints its usage and exits 2" {
    const result = try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = &.{ test_paths.emulator, "ctl", "--connect", "unix:/nonexistent/ctl.sock", "--json", "fly" },
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    try std.testing.expectEqual(Term{ .Exited = 2 }, result.term);
    try std.testing.expect(std.mem.endsWith(u8, result.stderr, ctl.usage));
}

test "ctl parse: --json anywhere, register names, budgets and memory reads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const regs = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "tcp::7000", "regs", "pc", "sp", "--json" });
    try std.testing.expect(regs.json);
    try std.testing.expectEqualSlices(ra8.interfaces.rpc.session.Register, &.{ .pc, .sp }, regs.command.regs);
    const ran = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "run", "--budget", "0x10" });
    try std.testing.expect(!ran.json);
    try std.testing.expectEqual(@as(u64, 16), ran.command.run);
    const mem = try ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "mem", "0x20000000", "8" });
    try std.testing.expectEqual(@as(u32, 0x2000_0000), mem.command.mem.address);
    try std.testing.expectError(error.UnknownRegister, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "regs", "r99" }));
    try std.testing.expectError(error.BadLength, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "mem", "0", "0" }));
    try std.testing.expectError(error.BadArguments, ctl.parse(a, &.{ "ra8", "ctl", "--connect", "unix:/s", "--json" }));
}
