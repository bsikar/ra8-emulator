//! Covers src/interfaces/cli/zig_snapshot.zig: a run saved part way and
//! restored ends where the uninterrupted run ends (RA8EMU-696), wherever the
//! split falls: a save holds the chunk it stopped in open instead of closing
//! it short, and the load picks it up there (RA8EMU-700).
const std = @import("std");
const ra8 = @import("ra8");

const memmap = ra8.core.memmap;
const elf = ra8.core.elf;
const zig_run = ra8.board.zig_run;
const main_path = zig_run.main_path;
const Cpu0 = zig_run.cpu0_memory.Cpu0;
const Parts = ra8.board.parts.Parts;
const Options = ra8.core.cli.Options;

const stkof = @embedFile("../../fixtures/threadx/threadx_stkof.elf");
const page: usize = 0x1000;
const vectors: u32 = memmap.mram_base;
const stack: u32 = memmap.sram_base + 0x800;

/// SP, reset, then a loop that counts r0 up and stores it to SRAM, so the
/// core, memory and the run's time all move.
fn image() [page * 2]u8 {
    var file = [_]u8{0} ** (page * 2);
    const head: *elf.Header = @ptrCast(@alignCast(&file[0]));
    head.* = .{ .magic = .{ 0x7f, 'E', 'L', 'F' }, .class = 1, .data = 1, .version = 1, .osabi = 0, .abiversion = 0, .pad = .{0} ** 7, .e_type = 2, .e_machine = elf.em_arm, .e_version = 1, .e_entry = vectors + 9, .e_phoff = @sizeOf(elf.Header), .e_shoff = 0, .e_flags = 0, .e_ehsize = @sizeOf(elf.Header), .e_phentsize = @sizeOf(elf.ProgramHeader), .e_phnum = 1, .e_shentsize = 0, .e_shnum = 0, .e_shstrndx = 0 };
    const header: *elf.ProgramHeader = @ptrCast(@alignCast(&file[@sizeOf(elf.Header)]));
    header.* = .{ .p_type = elf.pt_load, .p_offset = page, .p_vaddr = vectors, .p_paddr = vectors, .p_filesz = 0x10, .p_memsz = 0x10, .p_flags = 5, .p_align = 4 };
    std.mem.writeInt(u32, file[page..][0..4], stack, .little);
    std.mem.writeInt(u32, file[page + 4 ..][0..4], vectors + 9, .little);
    // adds r0, #1 ; str r0, [sp] ; b .-4
    for ([_]u16{ 0x3001, 0x9000, 0xE7FC }, 0..) |half, at| std.mem.writeInt(u16, file[page + 8 + at * 2 ..][0..2], half, .little);
    return file;
}

fn run(dir: std.fs.Dir, instructions: usize, state: zig_run.state_args.Options) !void {
    var file = image();
    try runImage(dir, &file, instructions, state);
}

fn runImage(dir: std.fs.Dir, file: []const u8, instructions: usize, state: zig_run.state_args.Options) !void {
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    const options: Options = .{ .path = "cpu0.elf", .cpu = .zig, .instructions = instructions, .state = state };
    try main_path.fit(&board, std.testing.allocator, options);
    var cpu0: Cpu0 = .{};
    defer cpu0.close();
    var parts = Parts{};
    const loaded = try elf.Image.init(file);
    _ = try main_path.prepare(&cpu0, &board, loaded, &parts, options);
    var log = try dir.createFile("run.log", .{});
    defer log.close();
    _ = try zig_run.run(log.writer(), cpu0.own(), &board, &parts.timebase, loaded, options, vectors, null, parts.tap.waiting(), .{});
}

fn read(dir: std.fs.Dir, name: []const u8) ![]u8 {
    return dir.readFileAlloc(std.testing.allocator, name, 1 << 28);
}

test "two chunks straight end where one chunk, saved, then one restored end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const paths = [_][]const u8{ "straight", "half", "resumed" };
    var full: [3][]u8 = undefined;
    for (paths, 0..) |name, at| full[at] = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer for (full) |one| std.testing.allocator.free(one);
    const chunk: usize = ra8.periph.clocks.chunk_instructions;
    try run(tmp.dir, chunk * 2, .{ .save = full[0] });
    try run(tmp.dir, chunk, .{ .save = full[1] });
    try run(tmp.dir, chunk, .{ .load = full[1], .save = full[2] });
    const straight = try read(tmp.dir, "straight");
    defer std.testing.allocator.free(straight);
    const resumed = try read(tmp.dir, "resumed");
    defer std.testing.allocator.free(resumed);
    const half = try read(tmp.dir, "half");
    defer std.testing.allocator.free(half);
    try std.testing.expect(!std.mem.eql(u8, straight, half));
    try std.testing.expectEqualSlices(u8, straight, resumed);
}

test "a split off a chunk boundary ends where the straight run ends too" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const paths = [_][]const u8{ "straight", "half", "resumed" };
    var full: [3][]u8 = undefined;
    for (paths, 0..) |name, at| full[at] = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer for (full) |one| std.testing.allocator.free(one);
    const chunk: usize = ra8.periph.clocks.chunk_instructions;
    try run(tmp.dir, chunk * 2, .{ .save = full[0] });
    try run(tmp.dir, chunk + 1000, .{ .save = full[1] });
    try run(tmp.dir, chunk - 1000, .{ .load = full[1], .save = full[2] });
    const straight = try read(tmp.dir, "straight");
    defer std.testing.allocator.free(straight);
    const resumed = try read(tmp.dir, "resumed");
    defer std.testing.allocator.free(resumed);
    try std.testing.expectEqualSlices(u8, straight, resumed);
}

// RA8EMU-699: a real ThreadX image (tests/fixtures/threadx, RA8FW-503's
// threadx_stkof) split part way ends with the same console lines and the
// same state bytes as the run left alone: mid-run, and during boot before
// the firmware arms SysTick, where a loaded run hands its carried
// instructions back to the budget (RA8EMU-701).
test "threadx_stkof split mid-run or during boot ends where the straight run ends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const paths = [_][]const u8{ "straight", "half", "resumed" };
    var full: [3][]u8 = undefined;
    for (paths, 0..) |name, at| full[at] = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer for (full) |one| std.testing.allocator.free(one);
    const total: usize = 100_000;
    try runImage(tmp.dir, stkof, total, .{ .save = full[0] });
    const straight = try read(tmp.dir, "straight");
    defer std.testing.allocator.free(straight);
    try std.testing.expect(std.mem.indexOf(u8, straight, "stkof: PASS") != null);
    for ([_]usize{ 20_000, 50_001 }) |split| {
        try runImage(tmp.dir, stkof, split, .{ .save = full[1] });
        try runImage(tmp.dir, stkof, total - split, .{ .load = full[1], .save = full[2] });
        const resumed = try read(tmp.dir, "resumed");
        defer std.testing.allocator.free(resumed);
        try std.testing.expectEqualSlices(u8, straight, resumed);
    }
}

test "no flag, no hook" {
    var store = try ra8.core.cpu.memory.store.Store.init(null);
    defer store.deinit();
    var board = ra8.board.Board.init(std.testing.allocator);
    defer board.deinit();
    var timebase: ra8.periph.clocks.Clocks = .{};
    var clock: zig_run.Clock = .{ .memory = .{ .store = &store }, .board = &board, .timebase = &timebase };
    try std.testing.expect(zig_run.zig_snapshot.hook(&clock) == null);
    clock.state = .{ .save = "x" };
    const hook = zig_run.zig_snapshot.hook(&clock).?;
    try std.testing.expect(hook.loadFn == null and hook.saveFn != null);
}
