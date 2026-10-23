//! Covers process interruption and scratch cleanup for src/interfaces/cli/sweep/elf.zig.
const std = @import("std");
const ra8 = @import("ra8");
const cli_app = @import("cli_app");
const test_paths = @import("test_paths");

const sweep_elf = cli_app.sweep.elf;

const fixture = "tests/fixtures/sizing/ext_stream.elf";
const on_windows = @import("builtin").os.tag == .windows;
const on_darwin = @import("builtin").os.tag.isDarwin();
const win32 = ra8.host.win32;

fn onlySentinel(dir: std.Io.Dir) !void {
    var it = dir.iterate();
    const entry = (try it.next(std.testing.io)).?;
    try std.testing.expectEqualStrings("keep.board", entry.name);
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(std.testing.io));
    const bytes = try dir.readFileAlloc(std.testing.io, "keep.board", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("unrelated", bytes);
}

test "an interrupted sweep removes its scratch profile and preserves siblings" {
    try interruptedCase(.interrupt);
}

test "sweep cleans scratch after Ctrl-C or SIGTERM" {
    try interruptedCase(.termination);
}

const Signal = enum { interrupt, termination };

fn interruptedCase(signal: Signal) !void {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "keep.board", .data = "unrelated" });
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(base);
    var child = try interruptedSweep(gpa, base, signal);
    const started = try provenance(&child);
    var reaped = false;
    errdefer {
        if (!reaped) {
            if (provenance(&child)) |now| {
                if (now == started and live(&child)) {
                    std.debug.print("CLEANUP verified pid={d} birth={d}\n", .{ if (on_windows) win32.GetProcessId(child.id.?) else @as(u32, @intCast(child.id.?)), now });
                    child.kill(std.testing.io);
                }
            } else |err| std.debug.print("CLEANUP identity check failed: {s}\n", .{@errorName(err)});
        }
    }
    // A ready marker is emitted after reservation and handler installation.
    var buffer: [256]u8 = undefined;
    var at: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        var into = [_][]u8{&byte};
        if (try child.stderr.?.readStreaming(std.testing.io, &into) == 0) return error.EndOfStream;
        if (byte[0] == '\n') {
            if (std.mem.eql(u8, buffer[0..at], "sweep: scratch profile ready")) break;
            at = 0;
        } else {
            if (at == buffer.len) return error.LineTooLong;
            buffer[at] = byte[0];
            at += 1;
        }
    }
    std.debug.print("owned sweep pid={d} scratch-directory={s} mode={s}\n", .{ if (on_windows) win32.GetProcessId(child.id.?) else @as(u32, @intCast(child.id.?)), base, @tagName(signal) });
    try std.testing.expectEqual(started, try provenance(&child));
    try std.testing.expect(live(&child));
    std.debug.print("EVENT ready=true live=true pid={d} birth={d} mode={s}\n", .{ if (on_windows) win32.GetProcessId(child.id.?) else @as(u32, @intCast(child.id.?)), started, @tagName(signal) });
    try interrupt(&child, signal);
    const result = try child.wait(std.testing.io);
    reaped = true;
    std.debug.print("CHILD_EXIT mode={s} result={any}\n", .{ @tagName(signal), result });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, result);
    try onlySentinel(tmp.dir);
    std.debug.print("SCRATCH mode={s} keep.board=unrelated owned=none\n", .{@tagName(signal)});
}

fn interruptedSweep(gpa: std.mem.Allocator, base: []const u8, signal: Signal) !std.process.Child {
    var env: std.process.Environ.Map = if (on_windows) try (std.process.Environ{ .block = .global }).createMap(gpa) else .init(gpa);
    defer env.deinit();
    try env.put(if (on_windows) "TMP" else "TMPDIR", base);
    const argv = [_][]const u8{ test_paths.emulator, "sweep", "--elf", fixture, "--ms", "1000" };
    if (!on_windows) return std.process.spawn(std.testing.io, .{ .argv = &argv, .environ_map = &env, .pgid = 0, .stdout = .ignore, .stderr = .pipe });
    const command = try sweepCommand(gpa);
    defer gpa.free(command);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, command);
    defer gpa.free(wide);
    const block = try env.createWindowsBlock(gpa, .{});
    defer block.deinit(gpa);
    const ends = try ra8.host.pipe_pair.create(.{});
    errdefer ra8.host.read.close(ends[0]);
    defer ra8.host.read.close(ends[1]);
    try std.testing.expect(win32.SetHandleInformation(ends[1], 1, 1).toBool());
    var startup: std.os.windows.STARTUPINFOW = std.mem.zeroes(std.os.windows.STARTUPINFOW);
    startup.cb = @sizeOf(@TypeOf(startup));
    startup.dwFlags = std.os.windows.STARTF_USESTDHANDLES | std.os.windows.STARTF_USESHOWWINDOW;
    startup.wShowWindow = 0;
    startup.hStdError = ends[1];
    var info: win32.ProcessInfo = undefined;
    // A new process group disables Ctrl-C for its root. Ctrl-Break needs it;
    // Ctrl-C instead uses the isolated console's broadcast group zero.
    const flags: std.os.windows.CreateProcessFlags = .{ .create_new_console = true, .create_new_process_group = signal == .interrupt, .create_unicode_environment = true };
    try std.testing.expect(win32.CreateProcessW(null, wide, null, null, .TRUE, @bitCast(flags), @ptrCast(@constCast(block.slice.ptr)), null, &startup, &info).toBool());
    std.debug.print("SPAWN mode={s} pid={d} argv={s} new_group={} new_console=true\n", .{ @tagName(signal), info.process_id, command, signal == .interrupt });
    return .{ .id = info.process, .thread_handle = info.thread, .stdin = null, .stdout = null, .stderr = .{ .handle = ends[0], .flags = .{ .nonblocking = false } }, .request_resource_usage_statistics = false };
}

fn sweepCommand(gpa: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa, "\"{s}\" sweep --elf \"{s}\" --ms 1000", .{ test_paths.emulator, fixture });
}

fn live(child: *std.process.Child) bool {
    if (!on_windows) return true;
    const zero: std.os.windows.LARGE_INTEGER = 0;
    return std.os.windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &zero) == .TIMEOUT;
}

fn interrupt(child: *std.process.Child, signal: Signal) !void {
    if (!on_windows) return std.posix.kill(-child.id.?, if (signal == .interrupt) .INT else .TERM);
    const pid = win32.GetProcessId(child.id.?);
    try std.testing.expect(pid != 0);
    _ = win32.FreeConsole();
    try std.testing.expect(win32.AttachConsole(pid).toBool());
    defer {
        _ = win32.FreeConsole();
        _ = win32.AttachConsole(std.math.maxInt(u32));
    }
    if (signal == .termination) {
        console_seen.store(false, .release);
        // The child was already created, so this per-process Ctrl-C mask
        // protects only the attached test process from the group-zero event.
        try std.testing.expect(win32.SetConsoleCtrlHandler(null, .TRUE).toBool());
        defer {
            if (!win32.SetConsoleCtrlHandler(null, .FALSE).toBool()) std.debug.print("PARENT Ctrl-C mask removal failed\n", .{});
        }
        try std.testing.expect(win32.SetConsoleCtrlHandler(testConsoleStop, .TRUE).toBool());
        defer {
            if (!win32.SetConsoleCtrlHandler(testConsoleStop, .FALSE).toBool()) std.debug.print("PARENT Ctrl-C handler removal failed\n", .{});
        }
        try std.testing.expect(win32.GenerateConsoleCtrlEvent(0, 0).toBool());
        try awaitChildExit(child);
        std.debug.print("PARENT Ctrl-C handler seen={} (diagnostic only)\n", .{console_seen.load(.acquire)});
    } else {
        try std.testing.expect(win32.GenerateConsoleCtrlEvent(1, pid).toBool());
        try awaitChildExit(child);
    }
}

fn awaitChildExit(child: *std.process.Child) !void {
    const timeout: std.os.windows.LARGE_INTEGER = -100_000_000;
    try std.testing.expectEqual(std.os.windows.NTSTATUS.SUCCESS, std.os.windows.ntdll.NtWaitForSingleObject(child.id.?, .FALSE, &timeout));
}

// Verify the exact owned executable and kernel birth identity before signals.
fn provenance(child: *std.process.Child) !i64 {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const expected = try std.Io.Dir.cwd().realPathFileAlloc(io, test_paths.emulator, gpa);
    defer gpa.free(expected);
    if (on_windows) {
        const windows = std.os.windows;
        var times: windows.KERNEL_USER_TIMES = undefined;
        try std.testing.expectEqual(windows.NTSTATUS.SUCCESS, windows.ntdll.NtQueryInformationProcess(child.id.?, .Times, &times, @sizeOf(@TypeOf(times)), null));
        var buffer: [8192]u8 align(@alignOf(windows.UNICODE_STRING)) = undefined;
        try std.testing.expectEqual(windows.NTSTATUS.SUCCESS, windows.ntdll.NtQueryInformationProcess(child.id.?, .ImageFileNameWin32, &buffer, buffer.len, null));
        const name: *const windows.UNICODE_STRING = @ptrCast(&buffer);
        const text = try std.unicode.utf16LeToUtf8Alloc(gpa, name.Buffer.?[0 .. name.Length / 2]);
        defer gpa.free(text);
        const actual = if (std.mem.startsWith(u8, text, "\\\\?\\") or std.mem.startsWith(u8, text, "\\??\\")) text[4..] else text;
        const wanted = if (std.mem.startsWith(u8, expected, "\\\\?\\")) expected[4..] else expected;
        try std.testing.expect(std.ascii.eqlIgnoreCase(actual, wanted));
        var command_buffer: [8192]u8 align(@alignOf(windows.UNICODE_STRING)) = undefined;
        try std.testing.expectEqual(windows.NTSTATUS.SUCCESS, windows.ntdll.NtQueryInformationProcess(child.id.?, .CommandLineInformation, &command_buffer, command_buffer.len, null));
        const command_string: *const windows.UNICODE_STRING = @ptrCast(&command_buffer);
        const command = try std.unicode.utf16LeToUtf8Alloc(gpa, command_string.Buffer.?[0 .. command_string.Length / 2]);
        defer gpa.free(command);
        const wanted_command = try sweepCommand(gpa);
        defer gpa.free(wanted_command);
        try std.testing.expectEqualStrings(wanted_command, command);
        std.debug.print("PROVENANCE pid={d} exe={s} birth={d} argv={s}\n", .{ win32.GetProcessId(child.id.?), actual, times.CreationTime, command });
        return times.CreationTime;
    }
    if (on_darwin) return libproc.birth(child.id.?, expected);
    const directory = try std.fmt.allocPrint(gpa, "/proc/{d}", .{child.id.?});
    defer gpa.free(directory);
    const exe = try std.fs.path.join(gpa, &.{ directory, "exe" });
    defer gpa.free(exe);
    const actual = try std.Io.Dir.cwd().realPathFileAlloc(io, exe, gpa);
    defer gpa.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    const path = try std.fs.path.join(gpa, &.{ directory, "stat" });
    defer gpa.free(path);
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var storage: [4096]u8 = undefined;
    var into = [_][]u8{&storage};
    const stat = storage[0..try file.readStreaming(io, &into)];
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.BadProcessStat;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    for (0..19) |_| _ = fields.next() orelse return error.BadProcessStat;
    const started = try std.fmt.parseInt(i64, fields.next() orelse return error.BadProcessStat, 10);
    std.debug.print("PROVENANCE pid={d} exe={s} birth_ticks={d}\n", .{ child.id.?, actual, started });
    return started;
}

/// Darwin has no /proc: libproc names a process's executable and start
/// time (RA8EMU-727), from <libproc.h> and <sys/proc_info.h>.
const libproc = struct {
    const pidtbsdinfo: c_int = 3;
    const path_max = 4 * 1024;

    /// struct proc_bsdinfo; only the start time is read.
    const BsdInfo = extern struct {
        ids: [12]u32,
        comm: [16]u8,
        name: [32]u8,
        counts: [6]u32,
        start_sec: u64,
        start_usec: u64,
    };

    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, size: u32) c_int;
    extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;

    fn birth(pid: std.posix.pid_t, expected: []const u8) !i64 {
        var path: [path_max]u8 = undefined;
        const len = proc_pidpath(pid, &path, path.len);
        if (len <= 0) return error.FileNotFound;
        try std.testing.expectEqualStrings(expected, path[0..@intCast(len)]);
        var info: BsdInfo = undefined;
        if (proc_pidinfo(pid, pidtbsdinfo, 0, &info, @sizeOf(BsdInfo)) != @sizeOf(BsdInfo)) return error.BadProcessStat;
        const started: i64 = @intCast(info.start_sec * 1_000_000 + info.start_usec);
        std.debug.print("PROVENANCE pid={d} exe={s} birth_us={d}\n", .{ pid, expected, started });
        return started;
    }
};

var console_seen = std.atomic.Value(bool).init(false);

fn testConsoleStop(_: win32.DWORD) callconv(.winapi) win32.BOOL {
    console_seen.store(true, .release);
    return .TRUE;
}
