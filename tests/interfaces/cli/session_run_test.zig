//! Covers src/interfaces/cli/session_run.zig and board_fit.zig (`RA8EMU-1233`,
//! F08): plain CLI `--camera-source` and `--history` runs record through
//! Session history, unrecordable raw-board flag combinations are refused with
//! exit code 2 without opening physical webcams, and both `image:PATH` and
//! real owned OS `pipe:...` runs record once and replay twice with identical
//! whole-machine state, console output and frames with zero live callbacks.
const std = @import("std");
const builtin = @import("builtin");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const rig = @import("../rpc/regression_rig.zig");

const cli = cli_app.cli;
const fitBoard = cli_app.zig.run.main_path.fit;
const session_run = cli_app.session_run;
const gpa = std.testing.allocator;

fn writeCameraEchoElf(dir: std.Io.Dir, name: []const u8) ![:0]u8 {
    const elf = ra8.board.image.elf;
    const ceu = ra8.chip.periph.ceu;
    var payload: [0x74]u8 = @splat(0);
    std.mem.writeInt(u32, payload[0x00..0x04], 0x2200_4000, .little);
    std.mem.writeInt(u32, payload[0x04..0x08], 0x2200_0009, .little);
    const code = [_]u16{
        0x4C07, 0xCC03, 0x2800, 0xD001, 0x6001, 0xE7FA,
        0x4A05, 0x4B06, 0x7850, 0x0900, 0x3041, 0x7018,
        0x200A, 0x7018, 0xE7FE, 0xBF00,
    };
    for (code, 0..) |op, idx| {
        std.mem.writeInt(u16, payload[0x08 + idx * 2 ..][0..2], op, .little);
    }
    std.mem.writeInt(u32, payload[0x28..0x2C], 0x2200_0034, .little);
    std.mem.writeInt(u32, payload[0x2C..0x30], 0x2200_1000, .little);
    std.mem.writeInt(u32, payload[0x30..0x34], 0x4035_8804, .little);
    const pairs = [_][2]u32{
        .{ 0x4020_3004, 0xFF7F_FFFF },
        .{ 0x4020_3008, 0xFFFE_FFFF },
        .{ 0x4035_8808, 0x0000_0010 },
        .{ ceu.win_base + ceu.off.capwr, 4 | (1 << ceu.field.vertical_shift) },
        .{ ceu.win_base + ceu.off.cdwdr, 4 },
        .{ ceu.win_base + ceu.off.cdayr, 0x2200_1000 },
        .{ ceu.win_base + ceu.off.capsr, ceu.field.capture_enable },
        .{ 0, 0 },
    };
    for (pairs, 0..) |pair, idx| {
        std.mem.writeInt(u32, payload[0x34 + idx * 8 ..][0..4], pair[0], .little);
        std.mem.writeInt(u32, payload[0x38 + idx * 8 ..][0..4], pair[1], .little);
    }

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
        .p_filesz = payload.len,
        .p_memsz = payload.len,
        .p_flags = 5,
        .p_align = 4,
    };
    try out.appendSlice(gpa, std.mem.asBytes(&head));
    try out.appendSlice(gpa, std.mem.asBytes(&load));
    try out.appendSlice(gpa, &payload);
    try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = out.items });
    return dir.realPathFileAlloc(std.testing.io, name, gpa);
}

fn expectMatchingReplay(rec: session_run.Outcome, rep: session_run.Outcome) !void {
    try std.testing.expectEqual(@as(u32, 1), rep.ceu_frames);
    try std.testing.expectEqual(@as(u64, 1), rep.replayed_frames);
    try std.testing.expectEqual(@as(u32, 0), rep.host_sink_lines);
    try std.testing.expectEqual(rec.console_lines, rep.console_lines);
    try std.testing.expectEqualStrings(rec.console_line, rep.console_line);
    // Run-command bookkeeping (slot clock, budgets) follows how the run was
    // chunked, so whole-machine equality is the history digest's.
    const digest = ra8.session.history_state_digest;
    const none: ra8.session.history_state_memory.Mask = .{ .a = null, .b = null };
    if (!try digest.equal(rec.state_bytes, rep.state_bytes, none)) {
        if (try digest.first(rec.state_bytes, rep.state_bytes, none)) |found| {
            std.debug.print("replay differs: {any}\n", .{found.place});
        }
        return error.ReplayStateDiffers;
    }
    try std.testing.expectEqualSlices(u32, rec.panel_pixels, rep.panel_pixels);
}

test "raw board refuses camera-source and session_run refuses unrecordable flags with exit 2" {
    var board = ra8.board.board.Board.init(gpa);
    defer board.deinit();
    const grad_opts = try cli.parse(&.{ "ra8_emulator", rig.image, "--camera-source", "gradient" });
    try std.testing.expectError(error.CameraRequiresSession, fitBoard(&board, gpa, std.testing.io, grad_opts));

    const bad_cases = [_][]const []const u8{
        &.{ "ra8_emulator", rig.image, "--camera-source", "gradient", "--save-state", "s.bin" },
        &.{ "ra8_emulator", rig.image, "--camera-source", "gradient", "--net-record", "p.pcap" },
        &.{ "ra8_emulator", rig.image, "--camera-source", "gradient", "--sd", "card.img" },
        &.{ "ra8_emulator", rig.image, "--camera-source", "gradient", "--part", "ra8d2" },
        &.{ "ra8_emulator", rig.image, "--camera-source", "gradient", "--sd-writable" },
        &.{ "ra8_emulator", rig.image, "--camera-source", "image:tests/fixtures/does-not-exist-1233.ppm" },
        &.{ "ra8_emulator", rig.image, "--kept" },
    };
    for (bad_cases) |argv| {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const opts = try cli.parse(argv);
        try std.testing.expectEqual(@as(u8, 2), try session_run.runWithOut(gpa, std.testing.io, opts, &out.writer));
        try std.testing.expectEqual(@as(usize, 0), out.written().len);
    }
}

test "plain CLI --camera-source image:PATH records once and replays twice offline" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const elf_path = try writeCameraEchoElf(scratch.dir, "cam.elf");
    defer gpa.free(elf_path);
    const elf_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .unlimited);
    defer gpa.free(elf_bytes);
    try scratch.dir.writeFile(std.testing.io, .{ .sub_path = "still.ppm", .data = "P6\n2 1\n255\n\xE0\x10\x20\xE0\x10\x20" });
    const root_dir = try scratch.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(root_dir);
    const spec = try std.fmt.allocPrint(gpa, "image:{s}/still.ppm", .{root_dir});
    defer gpa.free(spec);

    const options = try cli.parse(&.{ "ra8_emulator", elf_path, "--camera-source", spec, "--instructions", "50000", "--checkpoint-every", "1" });
    var bridges = std.heap.ArenaAllocator.init(gpa);
    defer bridges.deinit();
    var setup: ra8.rpc.served_setup.Served = undefined;
    _ = try session_run.openSession(&setup, &bridges, gpa, std.testing.io, elf_bytes, options);
    defer setup.deinit();
    var sink: session_run.ConsoleSink = .{};
    sink.bind(&setup, std.testing.io, false, null);

    const ended = try session_run.driveSession(&setup, &sink, options);
    var recorded = try session_run.captureOutcome(gpa, &setup, &sink, ended);
    defer recorded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), recorded.ceu_frames);
    try std.testing.expectEqual(@as(u32, 1), recorded.console_lines);
    try std.testing.expectEqual(@as(usize, 1), recorded.console_line.len);
    try std.testing.expectEqual(@as(u32, 1), recorded.host_sink_lines);

    try scratch.dir.deleteFile(std.testing.io, "still.ppm");

    var rep1 = try session_run.replayRun(gpa, &setup, &sink, options);
    defer rep1.deinit(gpa);
    try expectMatchingReplay(recorded, rep1);

    var rep2 = try session_run.replayRun(gpa, &setup, &sink, options);
    defer rep2.deinit(gpa);
    try expectMatchingReplay(recorded, rep2);
}

const WinKernel = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) std.os.windows.DWORD;
} else struct {};

const OwnedPipe = struct {
    spec_buf: [256]u8 = undefined,
    path_buf: [256]u8 = undefined,
    spec_len: usize = 0,
    path_len: usize = 0,

    fn prepare(self: *OwnedPipe, dir: std.Io.Dir) ![]const u8 {
        if (builtin.os.tag == .windows) {
            const pid = WinKernel.GetCurrentProcessId();
            const ns = std.Io.Timestamp.now(std.testing.io, .real).toNanoseconds();
            const name = try std.fmt.bufPrint(&self.path_buf, "ra8emu-1233-{d}-{d}", .{ pid, ns });
            self.path_len = name.len;
            const s = try std.fmt.bufPrint(&self.spec_buf, "pipe:{s},2x1,rgb24", .{name});
            self.spec_len = s.len;
            return s;
        }
        const root = try dir.realPathFileAlloc(std.testing.io, ".", gpa);
        defer gpa.free(root);
        const fifo = try std.fmt.bufPrint(&self.path_buf, "{s}/cam.fifo", .{root});
        self.path_len = fifo.len;
        const fifo_z = try std.posix.toPosixPath(fifo);
        if (builtin.os.tag == .linux) {
            if (std.os.linux.errno(std.os.linux.mknod(&fifo_z, std.os.linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return error.MkfifoFailed;
        } else {
            if (std.c.mkfifo(&fifo_z, 0o600) != 0) return error.MkfifoFailed;
        }
        const s = try std.fmt.bufPrint(&self.spec_buf, "pipe:{s},2x1,rgb24", .{fifo});
        self.spec_len = s.len;
        return s;
    }

    fn writeAndClose(self: *const OwnedPipe, frame: []const u8) !void {
        const path = self.path_buf[0..self.path_len];
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            const win32 = ra8.host.win32;
            var full_buf: [256]u8 = undefined;
            const full = try ra8.host.pipe.windows.fullName(&full_buf, path);
            var wide: [256:0]u16 = undefined;
            const len = try std.unicode.utf8ToUtf16Le(&wide, full);
            wide[len] = 0;
            const handle = win32.CreateFileW(wide[0..len :0], 0x4000_0000, 0, null, 3, 0, null);
            if (handle == windows.INVALID_HANDLE_VALUE) return error.PipeConnectFailed;
            defer windows.CloseHandle(handle);
            var written: windows.DWORD = 0;
            if (!win32.WriteFile(handle, frame.ptr, @intCast(frame.len), &written, null).toBool()) return error.PipeWriteFailed;
            if (written != frame.len) return error.ShortPipeWrite;
            return;
        }
        const z = try std.posix.toPosixPath(path);
        const rc = std.posix.system.open(&z, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, @as(c_uint, 0));
        if (std.posix.errno(rc) != .SUCCESS) return error.FifoOpenFailed;
        const fd: std.posix.fd_t = @intCast(rc);
        defer _ = std.c.close(fd);
        const n = std.c.write(fd, frame.ptr, frame.len);
        if (n != @as(isize, @intCast(frame.len))) return error.FifoWriteFailed;
    }
};

test "plain CLI --camera-source pipe:... records from a real OS pipe and replays twice with writer closed" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const elf_path = try writeCameraEchoElf(scratch.dir, "pipe-cam.elf");
    defer gpa.free(elf_path);
    const elf_bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, elf_path, gpa, .unlimited);
    defer gpa.free(elf_bytes);

    var pipe_rig: OwnedPipe = .{};
    const spec = try pipe_rig.prepare(scratch.dir);
    const options = try cli.parse(&.{ "ra8_emulator", elf_path, "--camera-source", spec, "--instructions", "50000", "--checkpoint-every", "1" });

    var bridges = std.heap.ArenaAllocator.init(gpa);
    defer bridges.deinit();
    var setup: ra8.rpc.served_setup.Served = undefined;
    _ = try session_run.openSession(&setup, &bridges, gpa, std.testing.io, elf_bytes, options);
    defer setup.deinit();
    var sink: session_run.ConsoleSink = .{};
    sink.bind(&setup, std.testing.io, false, null);

    // Stream one non-black RGB24 frame over the real OS pipe and close the writer.
    try pipe_rig.writeAndClose(&.{ 0xF0, 0xE0, 0xD0, 0xF0, 0xE0, 0xD0 });

    const ended = try session_run.driveSession(&setup, &sink, options);
    var recorded = try session_run.captureOutcome(gpa, &setup, &sink, ended);
    defer recorded.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 1), recorded.ceu_frames);
    try std.testing.expect(!std.mem.eql(u8, "A", recorded.console_line));

    var rep1 = try session_run.replayRun(gpa, &setup, &sink, options);
    defer rep1.deinit(gpa);
    try expectMatchingReplay(recorded, rep1);

    var rep2 = try session_run.replayRun(gpa, &setup, &sink, options);
    defer rep2.deinit(gpa);
    try expectMatchingReplay(recorded, rep2);
}

test "plain CLI --history DIR --kept with --camera-source persists a valid replayable session" {
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const elf_path = try writeCameraEchoElf(scratch.dir, "persisted.elf");
    defer gpa.free(elf_path);
    try scratch.dir.writeFile(std.testing.io, .{ .sub_path = "still.ppm", .data = "P6\n2 1\n255\n\x20\x90\xF0\x20\x90\xF0" });
    const dir_path = try scratch.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir_path);
    const spec = try std.fmt.allocPrint(gpa, "image:{s}/still.ppm", .{dir_path});
    defer gpa.free(spec);

    var hist_tmp = std.testing.tmpDir(.{});
    defer hist_tmp.cleanup();
    const hist_root = try hist_tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(hist_root);

    const options = try cli.parse(&.{ "ra8_emulator", elf_path, "--camera-source", spec, "--history", hist_root, "--kept", "--checkpoint-every", "1", "--instructions", "50000" });
    var report_out: std.Io.Writer.Allocating = .init(gpa);
    defer report_out.deinit();
    try std.testing.expectEqual(@as(u8, 0), try session_run.runWithOut(gpa, std.testing.io, options, &report_out.writer));
    try std.testing.expect(std.mem.indexOf(u8, report_out.written(), "CEU:") != null);
    try scratch.dir.deleteFile(std.testing.io, "still.ppm");

    var base = try ra8.host.history.base.Base.existing(gpa, std.testing.io, hist_root, .cache);
    defer base.close();
    var it = try ra8.host.history.catalog.Iterator.init(&base);
    const name = (try it.next()).?.name;
    var res = try ra8.rpc.regression_replay.run(gpa, std.testing.io, &base, name, elf_path, .{});
    defer res.deinit();
    try std.testing.expectEqual(ra8.rpc.regression_replay.Verdict.compatible, res.verdict);
    try std.testing.expect(res.checkpoints >= 2);
}
