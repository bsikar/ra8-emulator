//! Covers src/interfaces/rpc/session/cores.zig: single-core machines expose
//! only slot 0 on RPC `list_cores` and refuse `.cpu1` requests with `no_core`
//! (RA8EMU-1342).
const ra8 = @import("ra8");
const std = @import("std");

const cores_rpc = ra8.rpc.session.cores;
const cores_wire = ra8.rpc.session.cores_wire;
const disasm_rpc = ra8.rpc.session.disasm;
const handlers = ra8.rpc.session.handlers;
const load_chunks = ra8.rpc.session.load_chunks;
const machine_mod = ra8.chip.core.machine;
const map_rpc = ra8.rpc.session.map;
const periph_rpc = ra8.rpc.session.periph;
const server = ra8.rpc.session.server;
const set_var_rpc = ra8.rpc.session.set_var;

const fixture_elf = @embedFile("../../../fixtures/fpu/fp_basic.elf");

const sole_m85: machine_mod.Machine = .{
    .name = "sole-m85",
    .label = "SOLE-M85",
    .cores = .{
        .primary = machine_mod.core.cortexM85(.{
            .security = true,
            .fpu = .double,
            .systicks = 2,
        }),
    },
    .part = .ra8d2,
};

const sole_m33: machine_mod.Machine = .{
    .name = "sole-m33",
    .label = "SOLE-M33",
    .cores = .{
        .primary = machine_mod.core.cortexM33(.{
            .security = false,
            .fpu = .single,
            .systicks = 1,
        }),
    },
    .part = .ra8d2,
};

test "RPC list_cores omits CPU1 on single-core machines and refuses .cpu1 operations" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = fixture_elf,
        .machine = &sole_m85,
        .history_frames = 0,
    });
    defer opened.deinit();
    var scratch: [256]u8 = undefined;
    var context: server.Context = .{
        .session = opened.session(),
        .scratch = &scratch,
        .gpa = std.testing.allocator,
    };
    const listed = switch (cores_rpc.listCores(&context, .{})) {
        .ok => |ok| ok,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("sole-m85", listed.machine);
    try std.testing.expectEqual(@as(u8, 1), listed.count);
    try std.testing.expectEqual(@as(usize, 1), cores_wire.count(listed.bytes));
    const only = cores_wire.get(listed.bytes, 0);
    try std.testing.expectEqual(@as(u8, 0), only.slot);
    try std.testing.expectEqual(@as(u8, 1), only.attached);
    try std.testing.expectEqualStrings("Cortex-M85", only.nameSlice());

    const no_core: server.rpc_lib.Code = @fromBackingInt(@intCast(server.app_codes.no_core));
    try std.testing.expectEqual(no_core, handlers.readRegister(&context, .{ .core = .cpu1, .register = .pc }).err);
    try std.testing.expectEqual(
        no_core,
        load_chunks.loadBegin(&context, .{ .core = .cpu1, .total_len = 16, .checksum = 0 }).err,
    );
    try std.testing.expectEqual(no_core, map_rpc.map(&context, .{ .core = .cpu1 }).err);
    try std.testing.expectEqual(no_core, periph_rpc.periph(&context, .{ .core = .cpu1, .block = "" }).err);
    try std.testing.expectEqual(
        no_core,
        disasm_rpc.read(&context, .{ .core = .cpu1, .address = 0x0200_0000, .count = 1 }).err,
    );
    try std.testing.expectEqual(
        no_core,
        set_var_rpc.setVar(&context, .{ .core = .cpu1, .frame = 0, .name = "x", .value = "1" }).err,
    );
    try std.testing.expectEqual(no_core, handlers.setBreakpointNamed(&context, .{ .core = .cpu1, .name = "main" }).err);
    try std.testing.expectEqual(no_core, handlers.unsubscribe(&context, .{ .core = .cpu1, .topic = .uart }).err);
}

test "RPC loadEnd refuses an absent core before touching another core's assembly" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = fixture_elf,
        .machine = &sole_m85,
        .history_frames = 0,
    });
    defer opened.deinit();
    var scratch: [256]u8 = undefined;
    var context: server.Context = .{
        .session = opened.session(),
        .scratch = &scratch,
        .gpa = std.testing.allocator,
    };
    defer context.chunks.drop();
    const image = fixture_elf[0..64];
    const checksum = std.hash.Crc32.hash(image);
    _ = load_chunks.loadBegin(&context, .{ .core = .cpu0, .total_len = image.len, .checksum = checksum }).ok;
    _ = load_chunks.loadChunk(&context, .{ .core = .cpu0, .offset = 0, .bytes = image }).ok;
    const no_core: server.rpc_lib.Code = @fromBackingInt(@intCast(server.app_codes.no_core));
    try std.testing.expectEqual(no_core, load_chunks.loadEnd(&context, .{ .core = .cpu1 }).err);
    try std.testing.expectEqual(image.len, context.chunks.got);
    try std.testing.expectEqual(image.len, context.chunks.buffer.len);
}

test "RA8P1 keeps deferred named breaks and unsubscribe for a present but unattached CPU1" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = fixture_elf,
        .history_frames = 0,
    });
    defer opened.deinit();
    var scratch: [256]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    try std.testing.expect(!opened.session().hasCore(.cpu1));
    try std.testing.expect(!cores_rpc.absent(opened.session(), .cpu1));
    const refused: server.rpc_lib.Code = @fromBackingInt(@intCast(server.app_codes.refused));
    const named = handlers.setBreakpointNamed(&context, .{ .core = .cpu1, .name = "no_such_symbol" });
    try std.testing.expectEqual(refused, named.err);
    const unsubscribed = handlers.unsubscribe(&context, .{ .core = .cpu1, .topic = .uart });
    try std.testing.expectEqual(@as(u8, 1), unsubscribed.ok.accepted);
}

test "RPC list_cores reports sole M33 capabilities without MVE or LOB" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = fixture_elf,
        .machine = &sole_m33,
        .history_frames = 0,
    });
    defer opened.deinit();
    var scratch: [256]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    const listed = switch (cores_rpc.listCores(&context, .{})) {
        .ok => |ok| ok,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u8, 1), listed.count);
    const only = cores_wire.get(listed.bytes, 0);
    try std.testing.expectEqual(@as(u8, 0), only.flags);
    try std.testing.expectEqual(@as(u8, 1), only.fpu);
    try std.testing.expectEqual(@as(u8, 1), only.systicks);
    try std.testing.expectEqualStrings("Cortex-M33", only.nameSlice());
}

test "RPC list_cores reports both slots on RA8P1 with attachment state" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{
        .elf_bytes = fixture_elf,
        .history_frames = 0,
    });
    defer opened.deinit();
    var scratch: [256]u8 = undefined;
    var context: server.Context = .{ .session = opened.session(), .scratch = &scratch };
    const listed = switch (cores_rpc.listCores(&context, .{})) {
        .ok => |ok| ok,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("ra8p1", listed.machine);
    try std.testing.expectEqual(@as(u8, 2), listed.count);
    const c0 = cores_wire.get(listed.bytes, 0);
    const c1 = cores_wire.get(listed.bytes, 1);
    try std.testing.expectEqual(@as(u8, 0), c0.slot);
    try std.testing.expectEqual(@as(u8, 1), c0.attached);
    try std.testing.expectEqual(@as(u8, 1), c1.slot);
    try std.testing.expectEqual(@as(u8, 0), c1.attached);
    try std.testing.expectEqualStrings("Cortex-M33", c1.nameSlice());
}

test "every route opcode in server.routes is unique" {
    var codes: [server.routes.len]u16 = undefined;
    inline for (server.routes, 0..) |route, idx| codes[idx] = route[0];
    for (codes, 0..) |a, i| {
        for (codes[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
}
