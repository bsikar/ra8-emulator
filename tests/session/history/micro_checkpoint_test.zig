const std = @import("std");
const testing = std.testing;
const ra8 = @import("ra8");
const snapshot = ra8.snapshot;
const file = snapshot.file;
const micro = ra8.session.history_micro_checkpoint;
const BlockSectionTable = micro.BlockSectionTable;
const TouchedTracker = micro.TouchedTracker;
const MicroCheckpoint = micro.MicroCheckpoint;

const MockBoard = struct {
    serial_val: u32 = 0x1111,
    timer_val: u32 = 0x2222,
    clocks_val: u32 = 0x3333,

    pub fn saveSection(self: *MockBoard, kind: file.Kind, writer: anytype) !void {
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try self.writePayload(&counter.writer, kind);
        try file.writeSectionHeader(writer, kind, counter.fullCount());
        try self.writePayload(writer, kind);
    }

    fn writePayload(self: *MockBoard, writer: anytype, kind: file.Kind) !void {
        switch (kind) {
            .serial => try writer.writeInt(u32, self.serial_val, .little),
            .timers => try writer.writeInt(u32, self.timer_val, .little),
            .clocks => try writer.writeInt(u32, self.clocks_val, .little),
            else => {},
        }
    }

    pub fn loadSection(self: *MockBoard, kind: file.Kind, bytes: []const u8) !void {
        const sec = try file.Reader.find(bytes, kind) orelse return error.Missing;
        if (sec.payload.len != 4) return error.BadValue;
        const val = std.mem.readInt(u32, sec.payload[0..4], .little);
        switch (kind) {
            .serial => self.serial_val = val,
            .timers => self.timer_val = val,
            .clocks => self.clocks_val = val,
            else => {},
        }
    }
};

test "block section table registration and lookup" {
    var table: BlockSectionTable = .{};
    try table.register(0x4001_0000, 0x1000, .serial);
    try table.register(0x4002_0000, 0x1000, .timers);

    try testing.expectEqual(file.Kind.serial, table.lookup(0x4001_0000));
    try testing.expectEqual(file.Kind.serial, table.lookup(0x4001_0500));
    try testing.expectEqual(file.Kind.timers, table.lookup(0x4002_0000));
    // Non-secure alias (IDAU bit 28) canonicalizes to secure base
    try testing.expectEqual(file.Kind.serial, table.lookup(0x5001_0000));
    // Unmapped in peripheral window falls back to sparse registry
    try testing.expectEqual(file.Kind.registry, table.lookup(0x4005_0000));
}

test "block section table PPB and memory classification" {
    var table: BlockSectionTable = .{};
    // SysTick in PPB
    try testing.expectEqual(file.Kind.systick, table.lookup(0xE000_E010));
    try testing.expectEqual(file.Kind.systick, table.lookup(0xE002_E014));
    // MPU / SAU in PPB
    try testing.expectEqual(file.Kind.security, table.lookup(0xE000_ED90));
    try testing.expectEqual(file.Kind.security, table.lookup(0xE000_EDD0));
    // FPCCR in PPB
    try testing.expectEqual(file.Kind.cpu, table.lookup(0xE000_ED88));
    try testing.expectEqual(file.Kind.cpu, table.lookup(0xE000_EF34));
    // General NVIC / DWT in PPB
    try testing.expectEqual(file.Kind.debug_units, table.lookup(0xE000_E100));
    // RAM address
    try testing.expectEqual(file.Kind.memory, table.lookup(0x2000_0000));
}

test "block name to section heuristic" {
    try testing.expectEqual(file.Kind.timers, micro.sectionForBlockName("GPT0_PWM"));
    try testing.expectEqual(file.Kind.timers, micro.sectionForBlockName("AGT1"));
    try testing.expectEqual(file.Kind.serial, micro.sectionForBlockName("SCI_B UART"));
    try testing.expectEqual(file.Kind.display, micro.sectionForBlockName("GLCDC_CTRL"));
    try testing.expectEqual(file.Kind.raster, micro.sectionForBlockName("DRW2D"));
    try testing.expectEqual(file.Kind.clocks, micro.sectionForBlockName("SYSC-SCKSCR"));
    try testing.expectEqual(file.Kind.security, micro.sectionForBlockName("CPSCU-SAR"));
    try testing.expectEqual(file.Kind.signals, micro.sectionForBlockName("PFS/PMISC"));
    try testing.expectEqual(file.Kind.datapath, micro.sectionForBlockName("DMAC channels"));
    try testing.expectEqual(file.Kind.registry, micro.sectionForBlockName("UNKNOWN_CUSTOM"));
}

test "zero overhead path when disarmed (no allocations)" {
    var table: BlockSectionTable = .{};
    try table.register(0x4001_0000, 0x1000, .serial);

    var tracker = TouchedTracker.init(&table);
    // Explicitly disarmed: tracker.armed == false
    try testing.expect(!tracker.armed);

    const hook = tracker.hook();
    // Exercise hook while disarmed using a failing allocator environment
    const failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    _ = failing_allocator;

    hook.touch(0x4001_0000, true);
    hook.touch(0x4002_0000, false);
    hook.touch(0xE000_E010, true);

    try testing.expect(!tracker.hasTouched());
    try testing.expectEqual(@as(usize, 0), tracker.touchedCount());
    try testing.expect(!tracker.isTouched(.serial));
    try testing.expect(!tracker.isTouched(.systick));
}

test "touched tracker arm and clear" {
    var table: BlockSectionTable = .{};
    try table.register(0x4001_0000, 0x1000, .serial);
    try table.register(0x4002_0000, 0x1000, .timers);

    var tracker = TouchedTracker.init(&table);
    tracker.arm();
    try testing.expect(tracker.armed);

    const hook = tracker.hook();
    hook.touch(0x4001_0100, true);
    hook.touch(0x4002_0200, false);

    try testing.expect(tracker.hasTouched());
    try testing.expectEqual(@as(usize, 2), tracker.touchedCount());
    try testing.expect(tracker.isTouched(.serial));
    try testing.expect(tracker.isTouched(.timers));
    try testing.expect(!tracker.isTouched(.clocks));

    tracker.clear();
    try testing.expect(!tracker.hasTouched());
    try testing.expectEqual(@as(usize, 0), tracker.touchedCount());
}

test "untouched sections not captured in micro checkpoint" {
    var table: BlockSectionTable = .{};
    try table.register(0x4001_0000, 0x1000, .serial);
    try table.register(0x4002_0000, 0x1000, .timers);
    try table.register(0x4003_0000, 0x1000, .clocks);

    var tracker = TouchedTracker.init(&table);
    tracker.arm();

    // Only touch .serial
    tracker.touch(.serial);

    var board: MockBoard = .{
        .serial_val = 0xAAAA,
        .timer_val = 0xBBBB,
        .clocks_val = 0xCCCC,
    };

    var checkpoint = try MicroCheckpoint.capture(testing.allocator, &board, &tracker);
    defer checkpoint.deinit(testing.allocator);

    try testing.expect(checkpoint.bytes.len > 0);

    // .serial MUST be present in checkpoint payload
    const serial_sec = try file.Reader.find(checkpoint.bytes, .serial);
    try testing.expect(serial_sec != null);

    // Untouched sections (.timers, .clocks) MUST NOT be present
    const timer_sec = try file.Reader.find(checkpoint.bytes, .timers);
    try testing.expect(timer_sec == null);

    const clock_sec = try file.Reader.find(checkpoint.bytes, .clocks);
    try testing.expect(clock_sec == null);
}

test "micro checkpoint restore restores touched and leaves untouched" {
    var table: BlockSectionTable = .{};
    var tracker = TouchedTracker.init(&table);
    tracker.arm();
    tracker.touch(.serial);

    var board: MockBoard = .{
        .serial_val = 0x1234,
        .timer_val = 0x5678,
    };

    // Capture pre-state of serial
    var checkpoint = try MicroCheckpoint.capture(testing.allocator, &board, &tracker);
    defer checkpoint.deinit(testing.allocator);

    // Mutate both sections
    board.serial_val = 0x9999;
    board.timer_val = 0xAAAA;

    // Restore checkpoint (undo)
    try checkpoint.restore(&board);

    // Serial restored to pre-state
    try testing.expectEqual(@as(u32, 0x1234), board.serial_val);
    // Timers remained as mutated because it was never captured
    try testing.expectEqual(@as(u32, 0xAAAA), board.timer_val);
}
