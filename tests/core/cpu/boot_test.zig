//! Covers src/core/cpu/boot.zig.
const std = @import("std");
const ra8 = @import("ra8");
const memmap = ra8.core.memmap;
const boot = ra8.core.cpu.boot;
const elf = ra8.core.elf;
const Engine = ra8.core.engine.Engine;
const Until = ra8.core.stop.until.Until;

/// A vector table at the base of SRAM pointing at code right after it:
/// bf00 nop ; f3af 8000 nop.w ; ba80, unallocated on Armv8-M.
fn loadTiny(core: *Engine) !void {
    const base = memmap.sram_base;
    var image: [16]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..16], &[_]u8{ 0x00, 0xBF, 0xAF, 0xF3, 0x00, 0x80, 0x80, 0xBA });
    try core.write(base, &image);
}

test "a zig run stops on the first unknown encoding and says where" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try loadTiny(&core);
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const status = try boot.run(stream.writer(), &core, memmap.sram_base, 100, null);
    try std.testing.expectEqual(@as(u8, 1), status);
    var want: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "zig core: unknown encoding at 0x{x:0>8}: 0xba80 after 2 instructions\n", .{memmap.sram_base + 0xE});
    try std.testing.expectEqualStrings(line, stream.getWritten());
}

test "a zig run that spends its budget is clean" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try loadTiny(&core);
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try std.testing.expectEqual(@as(u8, 0), try boot.run(stream.writer(), &core, memmap.sram_base, 1, null));
    try std.testing.expect(std.mem.startsWith(u8, stream.getWritten(), "zig core: ran 1 instructions clean"));
}

test "no vector table is said plainly" {
    var core = try Engine.open();
    defer core.close();
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try std.testing.expectEqual(@as(u8, 1), try boot.run(stream.writer(), &core, memmap.sram_base, 1, null));
    try std.testing.expect(std.mem.startsWith(u8, stream.getWritten(), "zig core: no vector table"));
}

/// Counts the boundaries a run closes and how many instructions they carry.
const Edges = struct {
    width: u32,
    closes: u32 = 0,
    charged: u64 = 0,

    fn boundary(self: *Edges) boot.Boundary {
        return .{ .context = self, .widthFn = widthOf, .closeFn = closeOf };
    }

    fn widthOf(context: *anyopaque) u32 {
        const self: *Edges = @ptrCast(@alignCast(context));
        return self.width;
    }

    fn closeOf(context: *anyopaque, instructions: u32) anyerror!void {
        const self: *Edges = @ptrCast(@alignCast(context));
        self.closes += 1;
        self.charged += instructions;
    }
};

/// A vector table at the base of SRAM pointing at `b .` (0xe7fe).
fn loadSpin(core: *Engine) !void {
    const base = memmap.sram_base;
    var image: [10]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..10], &[_]u8{ 0xFE, 0xE7 });
    try core.write(base, &image);
}

test "a zig run on the board closes a boundary after every stretch, the short last one too" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try loadSpin(&core);
    var edges: Edges = .{ .width = 3 };
    var ran: u64 = 0;
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var periph = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(stream.writer(), &core, &periph, memmap.sram_base, 10, &ran, .{ .boundary = edges.boundary() });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 10), ran);
    try std.testing.expectEqual(@as(u32, 4), edges.closes);
    try std.testing.expectEqual(@as(u64, 10), edges.charged);
}

test "a stretch the core stops inside is never closed" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try loadTiny(&core);
    var edges: Edges = .{ .width = 5 };
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var periph = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(stream.writer(), &core, &periph, memmap.sram_base, 100, null, .{ .boundary = edges.boundary() });
    try std.testing.expectEqual(@as(u8, 1), status);
    try std.testing.expectEqual(@as(u32, 0), edges.closes);
}

test "a console success reached before an unknown encoding ends the Zig run" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try loadTiny(&core);
    var edges: Edges = .{ .width = 5 };
    var until = Until{ .needle = "PASS", .seen = true };
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var periph = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(
        stream.writer(),
        &core,
        &periph,
        memmap.sram_base,
        100,
        null,
        .{ .boundary = edges.boundary(), .until = &until },
    );
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expect(until.reached);
    try std.testing.expectEqual(@as(u32, 0), edges.closes);
    try std.testing.expectEqualStrings(
        "zig core: ran 1 instructions clean, pc 0x2200000A\nstopped clean on the console line \"PASS\", pc 0x2200000A\n",
        stream.getWritten(),
    );
}

/// A vector table at the base of SRAM pointing at an idle loop:
/// bf30 wfi ; e7fd b back to the wfi.
fn loadIdle(core: *Engine) !void {
    const base = memmap.sram_base;
    var image: [12]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 8) | 1, .little);
    @memcpy(image[8..12], &[_]u8{ 0x30, 0xBF, 0xFD, 0xE7 });
    try core.write(base, &image);
}

test "a core asleep in wfi closes every stretch at once without retiring" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try loadIdle(&core);
    var edges: Edges = .{ .width = 4 };
    var ran: u64 = 0;
    var buf: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var periph = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.runOnBoard(stream.writer(), &core, &periph, memmap.sram_base, 20, &ran, .{ .boundary = edges.boundary() });
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 1), ran);
    try std.testing.expectEqual(@as(u32, 5), edges.closes);
    try std.testing.expectEqual(@as(u64, 20), edges.charged);
}

const pacbti_image = @embedFile("../../fixtures/pacbti/pacbti_smoke.elf");

test "a PACBTI-built firmware image runs through the Zig core" {
    try std.testing.expect(std.mem.indexOf(u8, pacbti_image, &.{ 0xAF, 0xF3, 0x0D, 0x80 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, pacbti_image, &.{ 0xAF, 0xF3, 0x0F, 0x80 }) != null);
    try std.testing.expect(std.mem.indexOf(u8, pacbti_image, &.{ 0xAF, 0xF3, 0x2D, 0x80 }) != null);

    const image = try elf.Image.init(pacbti_image);
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    var segment_index: u16 = 0;
    while (segment_index < image.segmentCount()) : (segment_index += 1) {
        const segment = image.loadSegment(segment_index) orelse continue;
        try core.write(segment.paddr, segment.bytes);
    }

    var output: [128]u8 = undefined;
    var stream = std.io.fixedBufferStream(&output);
    var retired: u64 = 0;
    const vector_base = image.vectorBase() orelse return error.MissingVectorTable;
    var periph = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    const status = try boot.start(stream.writer(), .zig, image, &core, &periph, vector_base, 100, &retired, .{});
    try std.testing.expectEqual(@as(u8, 0), status);
    try std.testing.expectEqual(@as(u64, 100), retired);
    try std.testing.expectEqual(@as(u32, 0x247), try core.readWord(memmap.sram_base));
    try std.testing.expect(std.mem.startsWith(u8, stream.getWritten(), "zig core: ran 100 instructions clean"));
}

/// Reset branches to an even address with UsageFault disabled; HardFault
/// spins. movs r0, #0 ; bx r0 ; then b . as the NMI and HardFault handler.
fn loadEvenBranch(core: *Engine) !void {
    const base = memmap.sram_base;
    var image: [0x16]u8 = undefined;
    std.mem.writeInt(u32, image[0..4], base + 0x1000, .little);
    std.mem.writeInt(u32, image[4..8], (base + 0x10) | 1, .little);
    std.mem.writeInt(u32, image[8..12], (base + 0x14) | 1, .little);
    std.mem.writeInt(u32, image[12..16], (base + 0x14) | 1, .little);
    @memcpy(image[0x10..0x16], &[_]u8{ 0x00, 0x20, 0x00, 0x47, 0xFE, 0xE7 });
    try core.write(base, &image);
}

test "a board run that took INVSTATE reports CFSR and HFSR.FORCED (RA8EMU-394)" {
    var core = try Engine.open();
    defer core.close();
    try core.mapBoardRam();
    try loadEvenBranch(&core);
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var periph = ra8.periph.registry.Bus.init(std.testing.allocator);
    defer periph.deinit();
    _ = try boot.runOnBoard(stream.writer(), &core, &periph, memmap.sram_base, 50, null, .{});
    const line = "faults: CFSR 0x00020000 invstate, HFSR 0x40000000 forced, SFSR 0x00000000\n";
    std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), line) != null) catch |err| {
        std.debug.print("report was: {s}\n", .{stream.getWritten()});
        return err;
    };
}
