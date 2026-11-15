//! Whole-run recovery after debugger writes, including CPU1 and load lifetime.
const std = @import("std");
const ra8 = @import("ra8");
const Journal = ra8.session.write_undo.Journal;
const fixture = @import("board/state_fixture.zig");
const Rig = fixture.Rig;
const History = ra8.session.history.History;
const elf_path = "tests/fixtures/dfu/dfu_bootloader.elf";
const host_files = ra8.host.session_files.cwd(ra8.session.file_ops.Ops);
const address = ra8.chip.core.memmap.sram_base + 0x400;

fn equalState(rig: *Rig, expected: []const u8) !void {
    var actual = try rig.save();
    defer actual.deinit();
    try std.testing.expectEqualSlices(u8, expected, actual.written());
}

test "undo restores every saved guest field and orders edits across both cores" {
    const rig = try Rig.create();
    defer rig.destroy();
    try fixture.populated(rig);
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    var initial = try rig.save();
    defer initial.deinit();
    history.edits.loaded();
    try std.testing.expectEqual(@as(?anyerror, null), history.edits.unavailable);
    try rig.session.setRegister(.cpu1, .r4, 0x12345678);
    rig.board.time.base.base_ns += 100;
    rig.cpu.regs.low[6] = 0xABCDEF;
    var before_memory = try rig.save();
    defer before_memory.deinit();
    try rig.session.write(.cpu0, address, &.{ 99, 88 });
    try std.testing.expectEqual(@as(usize, 2), history.edits.entries.items.len);
    try rig.session.undoWrite();
    try equalState(rig, before_memory.written());
    try rig.session.undoWrite();
    try equalState(rig, initial.written());
    try std.testing.expectError(error.NoUndo, rig.session.undoWrite());
}

test "reset returns to the clean load snapshot and discards edits" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = elf_path, .files = host_files });
    defer opened.deinit();
    const session = opened.session();
    const initial_pc = try session.register(.cpu0, .pc);
    const initial_r0 = try session.register(.cpu0, .r0);
    try session.setRegister(.cpu0, .r0, 0x1234);
    _ = try session.step(.cpu0);
    try session.resetImage();
    try std.testing.expectEqual(initial_pc, try session.register(.cpu0, .pc));
    try std.testing.expectEqual(initial_r0, try session.register(.cpu0, .r0));
    try std.testing.expectError(error.NoUndo, session.undoWrite());
    try session.setRegister(.cpu0, .r0, 0x5678);
    try session.undoWrite();
    try std.testing.expectEqual(initial_r0, try session.register(.cpu0, .r0));
}

test "successful reload replaces clean checkpoint while a refused load preserves it" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = elf_path, .files = host_files });
    defer opened.deinit();
    const session = opened.session();
    try session.setRegister(.cpu0, .r0, 0x1234);
    try session.load(.cpu0, opened.state.bytes);
    const clean = try session.register(.cpu0, .r0);
    try std.testing.expectError(error.NoUndo, session.undoWrite());
    try session.setRegister(.cpu0, .r0, 0x9999);
    if (session.load(.cpu0, "not ELF")) |_| return error.InvalidLoadAccepted else |_| {}
    try session.resetImage();
    try std.testing.expectEqual(clean, try session.register(.cpu0, .r0));
}

test "failed writes do not add undo entries and recovery refuses while running" {
    var opened = try ra8.session.harness.open(std.testing.allocator, std.testing.io, .{ .elf_path = elf_path, .files = host_files });
    defer opened.deinit();
    const session = opened.session();
    try std.testing.expectError(error.CoreNotAttached, session.setRegister(.cpu1, .r0, 1));
    try std.testing.expectError(error.NoUndo, session.undoWrite());
    try session.setRegister(.cpu0, .r0, 42);
    session.live.machine.mode = .running;
    try std.testing.expectError(error.Running, session.undoWrite());
    try std.testing.expectError(error.Running, session.resetImage());
    session.live.machine.mode = .halted;
    try session.undoWrite();
}

test "the bounded edit journal drops only its oldest undo checkpoint" {
    const rig = try Rig.create();
    defer rig.destroy();
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    for (0..Journal.capacity + 2) |index| try rig.session.setRegister(.cpu0, .r0, @intCast(index + 1));
    try std.testing.expectEqual(Journal.capacity, history.edits.entries.items.len);
    for (0..Journal.capacity) |_| try rig.session.undoWrite();
    try std.testing.expectEqual(@as(u32, 2), try rig.session.register(.cpu0, .r0));
    try std.testing.expectError(error.NoUndo, rig.session.undoWrite());
}

test "partial dual-core wiring never pretends to save or restore CPU1" {
    const rig = try Rig.create();
    defer rig.destroy();
    rig.files.pair = null;
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    history.edits.loaded();
    try rig.session.setRegister(.cpu0, .r0, 5);
    try std.testing.expectEqual(@as(u32, 5), try rig.session.register(.cpu0, .r0));
    try std.testing.expectError(error.SecondCoreNotSaved, rig.session.undoWrite());
    try std.testing.expectError(error.SecondCoreNotSaved, rig.session.resetImage());
}

test "external snapshot restore invalidates the old edit stack" {
    const rig = try Rig.create();
    defer rig.destroy();
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    var saved = try rig.save();
    defer saved.deinit();
    try rig.session.setRegister(.cpu0, .r0, 7);
    try rig.files.readFrom(saved.written());
    try std.testing.expectError(error.NoUndo, rig.session.undoWrite());
}

test "recovery refuses a recorder without a branch graph and a missing snapshot owner" {
    const rig = try Rig.create();
    defer rig.destroy();
    try std.testing.expectError(error.NoHistory, rig.session.undoWrite());
    try std.testing.expectError(error.NoHistory, rig.session.resetImage());
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    history.edits.loaded();
    try rig.session.setRegister(.cpu0, .r0, 7);
    var router = ra8.session.history_fork_router.ForkRouter.init(std.testing.allocator, null);
    defer router.deinit();
    rig.session.attachForkRouter(&router);
    try std.testing.expectError(error.RecordedHistoryActive, rig.session.undoWrite());
    try std.testing.expectError(error.RecordedHistoryActive, rig.session.resetImage());
    try std.testing.expectEqual(@as(u32, 7), try rig.session.register(.cpu0, .r0));
    try std.testing.expectEqual(@as(usize, 1), history.edits.entries.items.len);
}

test "checkpoint allocation failure refuses the edit before guest mutation" {
    const rig = try Rig.create();
    defer rig.destroy();
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    history.edits.allocator = failing.allocator();
    defer history.edits.allocator = std.testing.allocator;
    try std.testing.expectError(error.OutOfMemory, rig.session.setRegister(.cpu0, .r0, 55));
    try std.testing.expectEqual(@as(u32, 0), try rig.session.register(.cpu0, .r0));
    try std.testing.expectEqual(@as(usize, 0), history.edits.entries.items.len);
}

const Recorded = struct {
    graph: ra8.session.history_branch.BranchGraph,
    router: ra8.session.history_fork_router.ForkRouter,
    sink: @import("fork_fixture.zig").MockStorage,
    recorder: ra8.session.history_recorder.Recorder,

    fn init(self: *Recorded, rig: *Rig) !void {
        self.graph = try .init(std.testing.allocator);
        self.router = .init(std.testing.allocator, &self.graph);
        self.sink = .init(std.testing.allocator);
        self.recorder = try .init(std.testing.allocator, self.sink.storage(), .{});
        rig.session.grid = &rig.edge.saved;
        rig.session.attachForkRouter(&self.router);
        rig.session.attachPersistentRecorder(&self.recorder);
    }

    fn deinit(self: *Recorded) void {
        self.recorder.deinit();
        self.router.deinit();
        self.graph.deinit();
        self.sink.deinit();
    }
};

test "recorded same-position edits undo on new lines and replay their full state" {
    const rig = try Rig.create();
    defer rig.destroy();
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    history.edits.loaded();
    var recording: Recorded = undefined;
    try recording.init(rig);
    defer recording.deinit();
    try rig.session.setRegister(.cpu0, .r0, 11);
    try rig.session.setRegister(.cpu0, .r0, 22);
    try rig.session.undoWrite();
    try std.testing.expectEqual(@as(u32, 11), try rig.session.register(.cpu0, .r0));
    try rig.session.undoWrite();
    try std.testing.expectEqual(@as(u32, 0), try rig.session.register(.cpu0, .r0));
    try std.testing.expectEqual(@as(u32, 2), recording.router.active_line);
    try std.testing.expectEqual(recording.router.active_line, rig.edge.saved.at.branch);
    var feeder = ra8.session.history_replay_feeder.ReplayFeeder.init(std.testing.allocator);
    defer feeder.deinit();
    try feeder.loadFromLog(&recording.graph, recording.router.active_line, recording.sink.bytes.items);
    try std.testing.expectEqual(@as(usize, 1), feeder.count());
    try std.testing.expect(feeder.items.items[0].action == .restore);
    rig.cpu.regs.low[0] = 99;
    const log_length = recording.sink.bytes.items.len;
    try feeder.checkAndApply(&rig.session);
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(log_length, recording.sink.bytes.items.len);
    try std.testing.expectEqual(@as(u32, 2), rig.edge.saved.at.branch);
    try rig.session.setRegister(.cpu0, .r0, 33);
    try rig.session.resetImage();
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 3), recording.router.active_line);
    try std.testing.expectEqual(@as(usize, 0), history.edits.entries.items.len);
}

test "recorded restore allocation failure rolls back graph log and journal without guest changes" {
    const rig = try Rig.create();
    defer rig.destroy();
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    var recording: Recorded = undefined;
    try recording.init(rig);
    defer recording.deinit();
    var tape = ra8.session.history_trail.Recording.init(std.testing.allocator, .{ &rig.cpu.slots, &rig.pair.core.cpu.slots }, &rig.store);
    defer tape.deinit();
    // An empty window never calls the port; its line must still survive refusal.
    var window = ra8.session.history_window_engine.ReverseWindow.init(std.testing.allocator, undefined, &tape, &rig.store, 4096);
    defer window.deinit();
    window.line = 0;
    rig.session.window = &window;
    try rig.session.setRegister(.cpu0, .r0, 42);
    try recording.recorder.force();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    rig.board.nor.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, rig.session.undoWrite());
    rig.board.nor.allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 42), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 0), recording.router.active_line);
    try std.testing.expectEqual(@as(u32, 0), recording.recorder.segment.branch);
    try std.testing.expectEqual(@as(u32, 1), recording.graph.nodes.count());
    try std.testing.expectEqual(@as(?u32, 0), window.line);
    try std.testing.expectEqual(@as(usize, 0), recording.sink.seg_bytes.items.len);
    try std.testing.expectEqual(@as(usize, 1), history.edits.entries.items.len);
    try rig.session.undoWrite();
    try std.testing.expectEqual(@as(u32, 0), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(recording.router.active_line, window.line.?);
}

test "oversized recorded reset refuses before allocating a branch or mutating the machine" {
    const rig = try Rig.create();
    defer rig.destroy();
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    var recording: Recorded = undefined;
    try recording.init(rig);
    defer recording.deinit();
    history.edits.clean = .{ .bytes = try std.testing.allocator.alloc(u8, ra8.session.write_undo.max_snapshot_bytes + 1), .position = .{} };
    rig.cpu.regs.low[0] = 77;
    try std.testing.expectError(error.SnapshotTooLarge, rig.session.resetImage());
    try std.testing.expectEqual(@as(u32, 77), rig.cpu.regs.low[0]);
    try std.testing.expectEqual(@as(u32, 1), recording.graph.nodes.count());
    try std.testing.expectEqual(@as(u32, 0), recording.router.active_line);
    try std.testing.expectEqual(@as(usize, 0), recording.sink.bytes.items.len);
}

test "whole-machine recovery publishes both core refreshes and restored LED levels" {
    const rig = try Rig.create();
    defer rig.destroy();
    var history = try History.init(std.testing.allocator, &rig.files, 2);
    defer history.deinit();
    rig.session.history = &history;
    try rig.session.setRegister(.cpu0, .r0, 3);
    const subscription = try rig.session.subscribe();
    defer rig.session.unsubscribe(subscription);
    try rig.session.undoWrite();
    var events: [32]ra8.session.api.Event = undefined;
    const arrived = rig.session.pollEvents(subscription, &events).?;
    var rewound: [2]bool = .{ false, false };
    var leds: usize = 0;
    for (events[0..arrived.count]) |event| {
        if (event.kind == .rewound) rewound[@backingInt(event.core)] = true;
        if (event.kind == .led_changed) {
            leds += 1;
            try std.testing.expectEqual(rig.board.pins.ledLevel(event.payload.led.index) == 1, event.payload.led.level);
        }
    }
    try std.testing.expect(rewound[0] and rewound[1]);
    try std.testing.expect(leds > 0);
}
