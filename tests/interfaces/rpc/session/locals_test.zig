//! A capture test from a real session (RA8EMU-1187): the uart_irq_echo
//! fixture, the one image with .debug_frame and .symtab, stopped inside
//! ra8_sci_init; the locals ask at a chosen stack frame answers that
//! frame's own function's locals, and a frame past the chain is refused.
const std = @import("std");
const ra8 = @import("ra8");

const server = ra8.rpc.session.server;
const proto = ra8.rpc.session.rpc;
const locals_wire = ra8.rpc.locals_wire;
const handler = ra8.rpc.session.locals;

const image_path = "tests/fixtures/uart/uart_irq_echo.elf";
/// ra8_sci_init's first instruction (its symbol is 0x02001975).
const sci_init: u32 = 0x0200_1974;

fn imageOf(context: *anyopaque, core: usize) ?ra8.session.symbols.Image {
    const harness: *ra8.session.harness.Harness = @ptrCast(@alignCast(context));
    return harness.loadedImage(if (core == 0) .cpu0 else .cpu1);
}

fn noMap(_: *anyopaque, _: usize, _: bool, _: []u8) anyerror![]const u8 {
    return error.NoImage;
}

/// The fixture stopped on ra8_sci_init's first instruction.
fn stopped() !ra8.session.harness.Harness {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = image_path });
    errdefer opened.deinit();
    const session = opened.session();
    _ = try session.setBreakpoint(.cpu0, .{ .address = sci_init });
    session.live.budget = 200_000;
    _ = try session.run(.cpu0, .cont);
    try std.testing.expectEqual(sci_init, try session.register(.cpu0, .pc));
    return opened;
}

/// Ask frame `n`'s locals over the real handler; the server hands it the
/// loaded image, the way serve does.
fn ask(opened: *ra8.session.harness.Harness, scratch: []u8, n: u32) !proto.Locals {
    var context: server.Context = .{
        .session = opened.session(),
        .scratch = scratch,
        .mapping = .{ .context = opened, .mapFn = noMap, .imageFn = imageOf },
    };
    return switch (handler.localsAt(&context, .{ .core = .cpu0, .frame = n })) {
        .ok => |found| found,
        .err => |code| {
            std.debug.print("REFUSED code={d}\n", .{code});
            return error.Refused;
        },
    };
}

const Named = struct { name: []const u8 };

/// The local names a packed answer carries.
fn names(answer: proto.Locals) ![proto.locals_rows]Named {
    var found: [proto.locals_rows]Named = undefined;
    var reader: locals_wire.Reader = .{ .rest = answer.rows };
    var count: usize = 0;
    while (try reader.next()) |row| : (count += 1) found[count] = .{ .name = row.name };
    try std.testing.expectEqual(@as(usize, answer.count), count);
    return found;
}

test "a stop inside ra8_sci_init answers each frame's own locals" {
    var opened = try stopped();
    defer opened.deinit();
    {
        const session = opened.session();
        var view = session.view(.cpu0) catch |err| {
            std.debug.print("VIEW ERR {any}\n", .{err});
            return err;
        };
        const pc = view.register(.pc) catch |err| {
            std.debug.print("REG ERR {any}\n", .{err});
            return err;
        };
        std.debug.print("pc=0x{x}\n", .{pc});
        const image = opened.loadedImage(.cpu0) orelse return error.NoImage;
        const sections = ra8.session.dwarf.locals.ofImage(image);
        std.debug.print("info.len={d} abbrev.len={d} str.len={d}\n", .{ sections.info.len, sections.abbrev.len, sections.str.len });
        var into: [32]ra8.session.dwarf.locals.Local = undefined;
        const n = ra8.session.dwarf.locals.inFunction(sections, sci_init, &into) catch |err| {
            std.debug.print("INFUNC ERR {any}\n", .{err});
            return err;
        };
        std.debug.print("locals={d}\n", .{n});
    }
    var top_scratch: [proto.locals_bytes]u8 = undefined;
    var deep_scratch: [proto.locals_bytes]u8 = undefined;
    const top = try ask(&opened, &top_scratch, 0);
    try std.testing.expectEqual(proto.Core.cpu0, top.core);
    try std.testing.expect(top.count > 0);
    // Frame 2's call site sits in main, so its locals are main's, not the
    // top frame's.
    const deep = try ask(&opened, &deep_scratch, 2);
    try std.testing.expect(deep.count > 0);
    const top_names = try names(top);
    const deep_names = try names(deep);
    var shared: usize = 0;
    outer: for (top_names[0..top.count]) |a| {
        for (deep_names[0..deep.count]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) {
                shared += 1;
                continue :outer;
            }
        }
    }
    try std.testing.expect(shared < top.count);
}

test "a frame past the chain is refused" {
    var opened = try stopped();
    defer opened.deinit();
    var scratch: [proto.locals_bytes]u8 = undefined;
    try std.testing.expectError(error.Refused, ask(&opened, &scratch, 99));
}
