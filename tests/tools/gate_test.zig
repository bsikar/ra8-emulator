//! The gate checks its own arithmetic: what counts as a function, where one
//! ends, and how many lines a file has.
const std = @import("std");
const gate = @import("gate");

test "a function spans from its declaration to the brace that closes it" {
    const src =
        \\const std = @import("std");
        \\
        \\pub fn two(a: u32) u32 {
        \\    return a;
        \\}
        \\
        \\fn four() void {
        \\    if (true) {
        \\        return;
        \\    }
        \\}
        \\
    ;
    var scanner = gate.Scanner.init(src);

    const first = scanner.next().?;
    try std.testing.expectEqualStrings("two", first.name);
    try std.testing.expectEqual(@as(usize, 3), first.start_line);
    try std.testing.expectEqual(@as(usize, 3), first.lines);

    const second = scanner.next().?;
    try std.testing.expectEqualStrings("four", second.name);
    try std.testing.expectEqual(@as(usize, 7), second.start_line);
    try std.testing.expectEqual(@as(usize, 5), second.lines);

    try std.testing.expect(scanner.next() == null);
}

test "a method inside a container is its own function, a nested one is not" {
    const src =
        \\pub const Block = struct {
        \\    value: u32 = 0,
        \\
        \\    pub fn read(self: Block) u32 {
        \\        const helper = struct {
        \\            fn double(v: u32) u32 {
        \\                return v * 2;
        \\            }
        \\        };
        \\        return helper.double(self.value);
        \\    }
        \\};
        \\
    ;
    var scanner = gate.Scanner.init(src);

    const method = scanner.next().?;
    try std.testing.expectEqualStrings("read", method.name);
    try std.testing.expectEqual(@as(usize, 8), method.lines);
    try std.testing.expect(scanner.next() == null);
}

test "a declaration without a body is not a function" {
    try std.testing.expect(gate.declaredName("extern fn unicorn_open(arch: u32) c_int;") == null);
    try std.testing.expect(gate.declaredName("pub const Hook = *const fn (u64) void;") == null);
    try std.testing.expect(gate.declaredName("const total = fn_count(list);") == null);
    try std.testing.expect(gate.declaredName("    // fn read(self: Block) u32 {") == null);
}

test "a declaration with a body names itself, however it is qualified" {
    try std.testing.expectEqualStrings("run", gate.declaredName("fn run() void {").?);
    try std.testing.expectEqualStrings("run", gate.declaredName("pub fn run() void {").?);
    try std.testing.expectEqualStrings("run", gate.declaredName("pub inline fn run() void {").?);
    try std.testing.expectEqualStrings("run", gate.declaredName("pub export fn run(").?);
}

test "the last line counts whether or not the file ends in a newline" {
    try std.testing.expectEqual(@as(usize, 0), gate.countLines(""));
    try std.testing.expectEqual(@as(usize, 1), gate.countLines("one\n"));
    try std.testing.expectEqual(@as(usize, 1), gate.countLines("one"));
    try std.testing.expectEqual(@as(usize, 2), gate.countLines("one\ntwo"));
    try std.testing.expectEqual(@as(usize, 2), gate.countLines("one\ntwo\n"));
}
