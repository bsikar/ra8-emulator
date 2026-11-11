//! Covers src/interfaces/rpc/regression_replay.zig: a rebuild that is the
//! recorded image replays compatible at every checkpoint, a rebuild with
//! one patched literal diverges at a named place, and the recorded
//! history is the same bytes after either.
const std = @import("std");
const ra8 = @import("ra8");
const rig = @import("regression_rig.zig");

const replay = ra8.rpc.regression_replay;

test "a non-default recorded board profile is applied to the replay" {
    const gpa = std.testing.allocator;
    const profile = "version=1\nmemory_window_cycles=17\n";
    const recorded = try rig.Recorded.openProfile(gpa, 3, profile);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try ra8.session.history_root.decode(bytes);
    try std.testing.expectEqualStrings(profile, root.board_profile);
    try std.testing.expectEqual(ra8.snapshot.file.version, root.snapshot_version);
    try std.testing.expect(!std.mem.allEqual(u8, &root.emulator_commit, 0));
    try std.testing.expectEqual(@as(usize, 64), root.model_version.len);
    try std.testing.expectEqualStrings("ra8p1", root.part);
    try std.testing.expectEqual(ra8.session.history_root.Pace.virtual, root.pace);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.image, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.compatible, result.verdict);
    try std.testing.expectEqual(@as(u32, 3), result.checkpoints);
    try std.testing.expectEqual(@as(u32, 3), result.matched);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "an empty root line refuses a vacuous compatible verdict without changing history" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    var dir = try recorded.base.dir.openDir(std.testing.io, recorded.sessionName(), .{});
    defer dir.close(std.testing.io);
    try dir.writeFile(std.testing.io, .{ .sub_path = "log/events-0", .data = "" });
    const before = try rig.hashTree(gpa, recorded.base.dir);
    try std.testing.expectError(error.NoRootCheckpoints, replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.image, .{}));
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "checkpoints only on another branch cannot make the root comparison compatible" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    try recorded.checkpointLog(.{ .branch = 1 }, null);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    try std.testing.expectError(error.NoRootCheckpoints, replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), "missing-rebuilt.elf", .{}));
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "the recorded image replays compatible and leaves the history untouched" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    const before = try rig.hashTree(gpa, recorded.base.dir);

    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.image, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.compatible, result.verdict);
    try std.testing.expectEqual(@as(u32, 3), result.checkpoints);
    try std.testing.expectEqual(@as(u32, 3), result.matched);
    try std.testing.expectEqual(@as(u64, 2), result.round);
    try std.testing.expect(result.divergence == null);
    try std.testing.expect(result.elf.identical());
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "one patched literal diverges at the memory it moved and leaves the history untouched" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.open(gpa, 3);
    defer recorded.close(gpa);
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const path = try rig.patched(gpa, scratch.dir, "variant.elf");
    defer gpa.free(path);
    const before = try rig.hashTree(gpa, recorded.base.dir);

    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), path, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, result.verdict);
    try std.testing.expectEqual(@as(u32, 3), result.checkpoints);
    try std.testing.expectEqual(@as(u32, 1), result.matched);
    try std.testing.expect(!result.elf.identical());
    try std.testing.expectEqual(@as(u32, 1), result.elf.segments_changed);
    try std.testing.expectEqual(@as(?u32, 0x2000041), result.elf.first_changed_address);

    const d = result.divergence.?;
    try std.testing.expectEqual(@as(u64, 1), d.position.r);
    try std.testing.expectEqual(@as(u8, 0), d.core);
    try std.testing.expectEqual(@as(u32, 0x200003c), d.pc_expected);
    try std.testing.expectEqual(@as(u32, 0x200003c), d.pc_actual);
    try std.testing.expect(d.stopped == null);
    try std.testing.expect(d.symbol == null);
    const spot = d.place.?.memory;
    try std.testing.expectEqual(@as(u32, 0x22000100), spot.address);
    try std.testing.expectEqual(@as(u8, 4), spot.expected);
    try std.testing.expectEqual(@as(u8, 0), spot.actual);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

test "two executed cores replay twice from frozen bytes with the original tree unchanged" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.openDual(gpa, 4);
    defer recorded.close(gpa);
    const bytes = try recorded.rootBytes(gpa);
    defer gpa.free(bytes);
    const root = try ra8.session.history_root.decode(bytes);
    try std.testing.expectEqualSlices(u8, rig.dual_second, root.elf1.?.bytes);
    try std.testing.expectEqualSlices(u8, &ra8.session.history_root.identity(rig.dual_second), &root.elf1.?.identity);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    for (0..2) |_| {
        var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.dual_image, .{});
        defer result.deinit();
        try std.testing.expectEqual(replay.Verdict.compatible, result.verdict);
        try std.testing.expect(result.checkpoints > 1);
        try std.testing.expectEqual(result.checkpoints, result.matched);
        try std.testing.expect(result.round > 0);
        try std.testing.expect(result.divergence == null);
        try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
    }
}

test "a rebuilt CPU0 reset loop diverges in an executed dual recording" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.openDual(gpa, 4);
    defer recorded.close(gpa);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, rig.dual_image, gpa, .unlimited);
    defer gpa.free(bytes);
    const image = try ra8.board.image.elf.Image.init(bytes);
    const reset = ra8.session.symbols.addressOf(image, "Reset_Handler").? & ~@as(u32, 1);
    var patched = false;
    for (0..image.segmentCount()) |i| {
        const segment = image.loadSegment(@intCast(i)) orelse continue;
        if (reset < segment.paddr or reset - segment.paddr + 2 > segment.bytes.len) continue;
        const offset = @intFromPtr(segment.bytes.ptr) - @intFromPtr(bytes.ptr) + reset - segment.paddr;
        // Thumb B .: a valid executable rebuild that never leaves reset.
        @memcpy(bytes[offset..][0..2], &[_]u8{ 0xfe, 0xe7 });
        patched = true;
        break;
    }
    try std.testing.expect(patched);
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "reset-loop.elf", .data = bytes });
    const path = try temp.dir.realPathFileAlloc(std.testing.io, "reset-loop.elf", gpa);
    defer gpa.free(path);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), path, .{});
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, result.verdict);
    try std.testing.expectEqual(@as(u32, 1), result.matched);
    const d = result.divergence.?;
    try std.testing.expectEqual(@as(u8, 0), d.core);
    try std.testing.expectEqual(reset, d.pc_actual);
    try std.testing.expectEqualStrings("Reset_Handler", d.symbol.?.name);
    try std.testing.expectEqual(@as(u32, 0), d.symbol.?.offset);
    try std.testing.expect(d.place != null);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

const ChangeSecond = struct {
    pc: u32 = 0,
    fn prepare(context: *anyopaque, served: *ra8.rpc.served_setup.Served, _: []const u8) anyerror!void {
        const self: *ChangeSecond = @ptrCast(@alignCast(context));
        self.pc = served.second.?.cpu().regs.pc;
        served.second.?.cpu().regs.low[3] ^= 0x42;
    }
};

test "CPU1 state divergence reports its own PC and symbol without modifying history" {
    const gpa = std.testing.allocator;
    const recorded = try rig.Recorded.openDual(gpa, 3);
    defer recorded.close(gpa);
    const before = try rig.hashTree(gpa, recorded.base.dir);
    var change: ChangeSecond = .{};
    var result = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), rig.dual_image, .{ .prepare = .{ .context = &change, .prepareFn = ChangeSecond.prepare } });
    defer result.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, result.verdict);
    const d = result.divergence.?;
    try std.testing.expectEqual(@as(u32, 0), result.matched);
    try std.testing.expectEqual(@as(u8, 1), d.core);
    try std.testing.expectEqual(change.pc, d.pc_expected);
    try std.testing.expectEqual(change.pc, d.pc_actual);
    try std.testing.expectEqualStrings("r3", d.place.?.register.name);
    const image = try ra8.board.image.elf.Image.init(rig.dual_second);
    const symbol = ra8.session.symbols.inside(image, change.pc & ~@as(u32, 1)).?;
    try std.testing.expectEqualStrings(symbol.name, d.symbol.?.name);
    try std.testing.expectEqual(symbol.offset, d.symbol.?.offset);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

fn writeThumbRoElf(gpa: std.mem.Allocator, dir: std.Io.Dir, name: []const u8, payload: []const u8) ![:0]u8 {
    const elf = ra8.board.image.elf;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var head = std.mem.zeroes(elf.Header);
    head.magic = "\x7fELF".*;
    head.class = 1;
    head.data = 1;
    head.e_entry = 0x2200_0009;
    head.e_machine = elf.em_arm;
    head.e_phoff = @sizeOf(elf.Header);
    head.e_phentsize = @sizeOf(elf.ProgramHeader);
    head.e_phnum = 1;
    const load = elf.ProgramHeader{
        .p_type = elf.pt_load,
        .p_offset = @sizeOf(elf.Header) + @sizeOf(elf.ProgramHeader),
        .p_vaddr = 0x2200_0000,
        .p_paddr = 0x2200_0000,
        .p_filesz = @intCast(payload.len),
        .p_memsz = @intCast(payload.len),
        .p_flags = 5,
        .p_align = 4,
    };
    try out.appendSlice(gpa, std.mem.asBytes(&head));
    try out.appendSlice(gpa, std.mem.asBytes(&load));
    try out.appendSlice(gpa, payload);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = out.items });
    return dir.realPathFileAlloc(std.testing.io, name, gpa);
}

fn roProgram(const_word: u32, mutate_ro: bool) [0x28]u8 {
    var buf: [0x28]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0x00..0x04], 0x2200_4000, .little);
    std.mem.writeInt(u32, buf[0x04..0x08], 0x2200_0009, .little);
    const code = if (mutate_ro)
        [_]u16{ 0x4803, 0x4903, 0x7001, 0x4805, 0x4904, 0xBF00, 0xE7FE, 0xBF00 }
    else
        [_]u16{ 0xBF00, 0xBF00, 0xBF00, 0xBF00, 0xBF00, 0xBF00, 0xE7FE, 0xBF00 };
    for (code, 0..) |op, idx| {
        std.mem.writeInt(u16, buf[0x08 + idx * 2 ..][0..2], op, .little);
    }
    std.mem.writeInt(u32, buf[0x18..0x1C], 0x2200_0020, .little);
    std.mem.writeInt(u32, buf[0x1C..0x20], const_word, .little);
    std.mem.writeInt(u32, buf[0x20..0x24], 0xAAAA_AAAA, .little);
    std.mem.writeInt(u32, buf[0x24..0x28], 0x0000_0000, .little);
    return buf;
}

test "read-only constant rebuild replays compatible while post-load write to read-only memory diverges" {
    const gpa = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const orig_prog = roProgram(0x1111_1111, false);
    const ro_const_prog = roProgram(0x2222_2222, false);
    const ro_mut_prog = roProgram(0x1111_1111, true);
    const orig_path = try writeThumbRoElf(gpa, scratch.dir, "orig.elf", &orig_prog);
    defer gpa.free(orig_path);
    const const_path = try writeThumbRoElf(gpa, scratch.dir, "ro-const.elf", &ro_const_prog);
    defer gpa.free(const_path);
    const mut_path = try writeThumbRoElf(gpa, scratch.dir, "ro-mut.elf", &ro_mut_prog);
    defer gpa.free(mut_path);

    const recorded = try rig.Recorded.openStartup(gpa, 3, rig.small_profile, orig_path, null, .{});
    defer recorded.close(gpa);
    const before = try rig.hashTree(gpa, recorded.base.dir);

    var ok = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), const_path, .{});
    defer ok.deinit();
    try std.testing.expectEqual(replay.Verdict.compatible, ok.verdict);
    try std.testing.expect(!ok.elf.identical());
    try std.testing.expectEqual(@as(?u32, 0x2200_001C), ok.elf.first_changed_address);
    try std.testing.expectEqual(ok.checkpoints, ok.matched);

    var bad = try replay.run(gpa, std.testing.io, &recorded.base, recorded.sessionName(), mut_path, .{});
    defer bad.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, bad.verdict);
    const d = bad.divergence.?;
    try std.testing.expectEqual(@as(u32, 0), d.position.branch);
    try std.testing.expectEqual(@as(u32, 0x2200_0014), d.pc_expected);
    try std.testing.expectEqual(@as(u32, 0x2200_0014), d.pc_actual);
    const spot = d.place.?.memory;
    try std.testing.expectEqual(@as(u32, 0x2200_0020), spot.address);
    try std.testing.expectEqual(@as(u8, 0xAA), spot.expected);
    try std.testing.expectEqual(@as(u8, 0x20), spot.actual);
    try std.testing.expectEqualSlices(u8, &before, &(try rig.hashTree(gpa, recorded.base.dir)));
}

fn captureProgram(do_capture: bool) [0x68]u8 {
    const ceu = ra8.chip.periph.ceu;
    var buf: [0x68]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0x00..0x04], 0x2200_4000, .little);
    std.mem.writeInt(u32, buf[0x04..0x08], 0x2200_0009, .little);
    const code = [_]u16{ 0x4C03, 0xCC03, 0x2800, 0xD001, 0x6001, 0xE7FA, 0xE7FE, 0xBF00 };
    for (code, 0..) |op, idx| std.mem.writeInt(u16, buf[0x08 + idx * 2 ..][0..2], op, .little);
    std.mem.writeInt(u32, buf[0x18..0x1C], 0x2200_0020, .little);
    const pairs = [_][2]u32{
        .{ 0x4020_3008, 0xFFFE_FFFF },
        .{ ceu.win_base + ceu.off.capwr, 4 | (1 << ceu.field.vertical_shift) },
        .{ ceu.win_base + ceu.off.cdwdr, 4 },
        .{ ceu.win_base + ceu.off.cdayr, 0x2200_1000 },
        .{ if (do_capture) ceu.win_base + ceu.off.capsr else 0, ceu.field.capture_enable },
        .{ 0, 0 },
    };
    for (pairs, 0..) |pair, idx| {
        std.mem.writeInt(u32, buf[0x20 + idx * 8 ..][0..4], pair[0], .little);
        std.mem.writeInt(u32, buf[0x24 + idx * 8 ..][0..4], pair[1], .little);
    }
    return buf;
}

test "recorded camera frame replays offline while skipping it stops with replay_failed" {
    const gpa = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const cap_prog = captureProgram(true);
    const skip_prog = captureProgram(false);
    const cap_path = try writeThumbRoElf(gpa, scratch.dir, "cap.elf", &cap_prog);
    defer gpa.free(cap_path);
    const skip_path = try writeThumbRoElf(gpa, scratch.dir, "skip.elf", &skip_prog);
    defer gpa.free(skip_path);
    try scratch.dir.writeFile(std.testing.io, .{ .sub_path = "still.ppm", .data = "P6\n2 1\n255\n\x10\x20\x30\x40\x50\x60" });
    const dir_path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir_path);
    const spec = try std.fmt.allocPrint(gpa, "image:{s}/still.ppm", .{dir_path});
    defer gpa.free(spec);

    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    const root_path = try root_tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root_path);
    {
        var served: ra8.rpc.served_setup.Served = undefined;
        try served.openInputs(gpa, std.testing.io, cap_path, rig.small_profile, .{ .root = root_path, .checkpoint_every = 1, .kept = true }, null, .{});
        defer served.deinit();
        try ra8.rpc.served_camera.set(&served, try ra8.host.camera.source_spec.parse(spec));
        const session = served.owner.session();
        try session.setRunBudget(.cpu0, 40_000);
        _ = try session.run(.cpu0, .run);
        _ = try session.run(.cpu0, .cont);
        try std.testing.expectEqual(@as(u32, 1), served.owner.board().capture.frames);
    }
    try scratch.dir.deleteFile(std.testing.io, "still.ppm");

    var base = try ra8.host.history.base.Base.existing(gpa, std.testing.io, root_path, .cache);
    defer base.close();
    var it = try ra8.host.history.catalog.Iterator.init(&base);
    const name = (try it.next()).?.name;

    var ok = try replay.run(gpa, std.testing.io, &base, name, cap_path, .{});
    defer ok.deinit();
    try std.testing.expectEqual(replay.Verdict.compatible, ok.verdict);
    try std.testing.expect(ok.checkpoints >= 2);

    var missed = try replay.run(gpa, std.testing.io, &base, name, skip_path, .{});
    defer missed.deinit();
    try std.testing.expectEqual(replay.Verdict.diverged, missed.verdict);
    try std.testing.expectEqualStrings("replay_failed", missed.divergence.?.stopped.?);
    try std.testing.expectEqual(@as(u32, 0), missed.divergence.?.position.branch);
}

test "a root-line CPU0 load intervention is refused instead of clobbering the rebuilt ELF" {
    const gpa = std.testing.allocator;
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const prog = roProgram(0x1111_1111, false);
    const elf_path = try writeThumbRoElf(gpa, scratch.dir, "load.elf", &prog);
    defer gpa.free(elf_path);
    const elf_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .unlimited);
    defer gpa.free(elf_bytes);

    var root_tmp = std.testing.tmpDir(.{});
    defer root_tmp.cleanup();
    const root_path = try root_tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root_path);
    {
        var served: ra8.rpc.served_setup.Served = undefined;
        try served.openInputs(gpa, std.testing.io, elf_path, rig.small_profile, .{ .root = root_path, .checkpoint_every = 1, .kept = true }, null, .{});
        defer served.deinit();
        const session = served.owner.session();
        try session.setRunBudget(.cpu0, 40_000);
        _ = try session.run(.cpu0, .run);
        try session.load(.cpu0, elf_bytes);
        _ = try session.run(.cpu0, .cont);
    }
    var base = try ra8.host.history.base.Base.existing(gpa, std.testing.io, root_path, .cache);
    defer base.close();
    var it = try ra8.host.history.catalog.Iterator.init(&base);
    const name = (try it.next()).?.name;
    try std.testing.expectError(error.UnsupportedLoadIntervention, replay.run(gpa, std.testing.io, &base, name, elf_path, .{}));
}
