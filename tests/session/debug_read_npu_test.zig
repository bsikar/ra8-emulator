//! A debugger read over the NPU through the Zig core's board bus
//! (RA8EMU-948): aligned and unaligned windows answer as a read would, take
//! no traffic the guest could see, and leave the model armed; the guest's own
//! load still exercises it.
const std = @import("std");
const ra8 = @import("ra8");
const registry = ra8.chip.periph.registry;
const npu = ra8.chip.periph.npu;
const BoardBus = ra8.chip.core.cpu.board_bus.BoardBus;
const Banked = ra8.chip.core.banked.Banked;
const debug_read = ra8.session.step_hook.debug_read;
const quiet_source = ra8.chip.core.cpu.exception.quiet_source;
const bus = ra8.chip.core.cpu.bus;
const store_memory = @import("../chip/periph/store_memory.zig");

fn at(offset: u32) u32 {
    return npu.win_base + offset;
}

const Rig = struct {
    periph: registry.Bus,
    board: BoardBus,
};

fn board(npu_unit: *npu.Npu, memory: anytype) !Rig {
    var periph = registry.Bus.init(std.testing.allocator);
    try periph.add(npu_unit.block());
    var secure_mpu = ra8.chip.periph.mpu.Mpu.init();
    var ns_mpu = ra8.chip.periph.mpu.Mpu.init();
    var state: Banked = .{};
    const answer = Rig{
        .periph = periph,
        .board = .{
            .memory = .{ .store = .{ .store = memory.store } },
            .periph = &periph,
            .security = &state,
            .scs = .{ .regions = &secure_mpu, .regions_ns = &ns_mpu },
        },
    };
    return answer;
}

test "a debugger read over the NPU answers and keeps it quiet" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var unit = npu.Npu.init();
    var rig = try board(&unit, memory);
    defer rig.periph.deinit();

    var seen: [4]u8 = undefined;
    try debug_read.read(rig.board.view(), at(npu.off.id), &seen);
    try std.testing.expectEqual(@as(u32, npu.identity), std.mem.readInt(u32, &seen, .little));
    // An unaligned window goes through as 1- and 2-byte pieces and answers
    // the same word.
    var unaligned: [3]u8 = undefined;
    try debug_read.read(rig.board.view(), at(npu.off.status) + 1, &unaligned);
    try std.testing.expectEqual(@as(u8, 0), unaligned[0]);
    try std.testing.expectEqual(@as(u8, 0), unaligned[1]);
    try std.testing.expectEqual(@as(u8, 0), unaligned[2]);

    try std.testing.expectEqual(@as(u32, 0), unit.reads);
    try std.testing.expect(unit.quiet());
}

test "a debugger read over a written NPU register answers the register" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var unit = npu.Npu.init();
    var rig = try board(&unit, memory);
    defer rig.periph.deinit();

    // A guest write the debugger then inspects: the register it landed in.
    unit.write(at(npu.off.basep0), 4, 0x2020_0000);
    var seen: [4]u8 = undefined;
    try debug_read.read(rig.board.view(), at(npu.off.basep0), &seen);
    try std.testing.expectEqual(@as(u32, 0x2020_0000), std.mem.readInt(u32, &seen, .little));
    var tail: [3]u8 = undefined;
    try debug_read.read(rig.board.view(), at(npu.off.basep0) + 1, &tail);
    // Bytes 1..3 of the word, little-endian: 0x00, 0x20, 0x20.
    try std.testing.expectEqual(@as(u24, 0x20_2000), std.mem.readInt(u24, &tail, .little));
    try std.testing.expectEqual(@as(u32, 0), unit.reads);

    // A guest read exercises the access: the traffic count and the arm move.
    var taken: [4]u8 = undefined;
    try rig.board.view().read(at(npu.off.basep0), &taken);
    try std.testing.expectEqual(@as(u32, 1), unit.reads);
    try std.testing.expect(!unit.quiet());
}

test "a debugger read over the NPU does not stir the answer a poll is resting on" {
    const memory = try store_memory.open();
    defer store_memory.close(memory);
    var unit = npu.Npu.init();
    var rig = try board(&unit, memory);
    defer rig.periph.deinit();

    const Stub = struct {
        fn winner(_: *anyopaque, _: bus.Bus) bus.Error!?ra8.chip.core.cpu.exception.active.Entry {
            return null;
        }
        fn taken(_: *anyopaque, _: bus.Bus, _: u9) bus.Error!void {}
        fn returned(_: *anyopaque, _: bus.Bus, _: u9) bus.Error!void {}
    };
    var stub = Stub{};
    var quiet = quiet_source.QuietSource{
        .inner = .{ .ctx = &stub, .vtable = &.{ .winner = Stub.winner, .taken = Stub.taken, .returned = Stub.returned } },
        .memory = rig.board.view(),
    };
    // One poll asked and found nothing, so the answer stands.
    _ = try quiet.source().winner(quiet.bus());
    try std.testing.expect(quiet.answered);
    try std.testing.expect(quiet.settled);

    // An inspection through the same bus answers from state and leaves the
    // standing answer alone.
    var seen: [4]u8 = undefined;
    try debug_read.read(quiet.bus(), at(npu.off.id), &seen);
    try std.testing.expectEqual(@as(u32, npu.identity), std.mem.readInt(u32, &seen, .little));
    try std.testing.expect(quiet.answered);
    try std.testing.expect(quiet.settled);
    try std.testing.expectEqual(@as(u32, 0), unit.reads);

    // A guest read of the same window stirs, as it always did.
    try quiet.bus().read(at(npu.off.id), &seen);
    try std.testing.expect(!quiet.settled);
}
