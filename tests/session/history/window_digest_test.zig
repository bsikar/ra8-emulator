const std = @import("std");
const testing = std.testing;
const ra8 = @import("ra8");
const slot_mod = ra8.session.history_window_slot;
const ArchState = slot_mod.ArchState;
const Position = slot_mod.Position;
const window_trail_mod = ra8.session.history_window_trail;
const WindowTrail = window_trail_mod.WindowTrail;
const trail_mod = ra8.session.history_trail;
const Recording = trail_mod.Recording;
const Store = ra8.chip.core.cpu.memory.store.Store;
const digest_mod = ra8.session.history_window_digest;
const micro_mod = ra8.session.history_micro_checkpoint;
const file = ra8.snapshot.file;

const MockBoard = struct {
    mmio_val: u32 = 0x1111,

    pub fn saveSection(self: *MockBoard, kind: file.Kind, writer: anytype) !void {
        if (kind != .registry) return;
        try file.writeSectionHeader(writer, kind, 4);
        try writer.writeInt(u32, self.mmio_val, .little);
    }

    pub fn loadSection(self: *MockBoard, kind: file.Kind, bytes: []const u8) !void {
        if (kind != .registry) return;
        const sec = try file.Reader.find(bytes, kind) orelse return error.Missing;
        if (sec.payload.len != 4) return error.BadValue;
        self.mmio_val = std.mem.readInt(u32, sec.payload[0..4], .little);
    }
};

test "digest calculation determinism and sensitivity" {
    var arch1: ArchState = .{};
    arch1.regs.low[0] = 123;
    const micro1 = "test_micro_payload_1";

    const d1 = digest_mod.computeDigest(&arch1, micro1);
    const d2 = digest_mod.computeDigest(&arch1, micro1);
    try testing.expectEqual(d1, d2);

    // Perturb register
    var arch2 = arch1;
    arch2.regs.low[0] = 124;
    const d3 = digest_mod.computeDigest(&arch2, micro1);
    try testing.expect(!std.mem.eql(u8, &d1, &d3));

    // Perturb micro payload
    const micro2 = "test_micro_payload_2";
    const d4 = digest_mod.computeDigest(&arch1, micro2);
    try testing.expect(!std.mem.eql(u8, &d1, &d4));
}

test "injected divergence detected with the right position" {
    var arch: ArchState = .{};
    arch.regs.pc = 0x1000;
    const expected = digest_mod.computeDigest(&arch, "correct_post_bytes");

    const pos = Position{
        .r = 42,
        .phase = .cpu0,
        .o = 17,
        .gap = .polled,
    };

    var refusal: digest_mod.DivergenceRefusal = undefined;

    // Redo produces divergent bytes
    const result = digest_mod.verifyRedoDigest(
        expected,
        &arch,
        "divergent_bytes_here",
        pos,
        .cpu0,
        &refusal,
    );

    try testing.expectError(error.HistoryDivergence, result);
    try testing.expectEqual(@as(u64, 42), refusal.position.r);
    try testing.expectEqual(pos.phase, refusal.position.phase);
    try testing.expectEqual(@as(u32, 17), refusal.position.o);
    try testing.expectEqual(pos.gap, refusal.position.gap);
    try testing.expectEqual(expected, refusal.expected_digest);
    try testing.expect(!std.mem.eql(u8, &refusal.expected_digest, &refusal.actual_digest));

    // Check visible refusal report format
    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try refusal.format(&writer);
    const report = writer.written();
    try testing.expect(std.mem.indexOf(u8, report, "HistoryDivergence at round=42") != null);
}

test "MMIO slot undo/redo round trip with matching digest" {
    var store = try Store.init(null);
    defer store.deinit();

    var slots: [2]u64 = .{ 0, 0 };
    var rec = Recording.init(testing.allocator, .{ &slots[0], &slots[1] }, &store);
    defer rec.deinit();

    var window = WindowTrail.init(testing.allocator, &rec, &store, 64 * 1024);
    defer window.deinit();

    var board = MockBoard{ .mmio_val = 0x1111 };
    var pre_arch: ArchState = .{};
    pre_arch.regs.low[0] = 0x10;
    pre_arch.regs.pc = 0x1000;

    const pos = Position{ .r = 1, .phase = .cpu0, .o = 0, .gap = .retired };
    window.startSlot(.cpu0, pos, &pre_arch);

    // Slot mutates MMIO and registers
    board.mmio_val = 0x2222;
    var post_arch = pre_arch;
    post_arch.regs.low[0] = 0x20;
    post_arch.regs.pc = 0x1004;

    const post_micro = "post_mmio_bytes_0x2222";
    try window.endSlotWithMicro(&post_arch, .complex, post_micro);

    try testing.expectEqual(@as(usize, 1), window.count);
    try testing.expectEqual(@as(usize, 1), window.cursor);

    // Undo: restores pre-state
    var cpu: ra8.chip.core.cpu.cpu.Cpu = undefined;
    post_arch.restore(&cpu);

    const undone = try window.undoOneWithBoard(&cpu, null, &board);
    try testing.expect(undone);
    try testing.expectEqual(@as(usize, 0), window.cursor);
    const restored_arch = ArchState.capture(&cpu);
    try testing.expectEqual(@as(u32, 0x10), restored_arch.regs.low[0]);
    try testing.expectEqual(@as(u32, 0x1000), restored_arch.regs.pc);

    // Redo with matching execution
    const re_exec = struct {
        fn run() !void {}
    }.run;

    // Set post state for redo target
    post_arch.restore(&cpu);
    const redone = try window.redoOneWithBoard(&cpu, null, &board, re_exec);
    try testing.expect(redone);
    try testing.expectEqual(@as(usize, 1), window.cursor);
}
