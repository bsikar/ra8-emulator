//! `ra8_emulator sweep --elf PATH` (RA8EMU-755): run a real image once per
//! board memory configuration instead of the synthetic workload. Each run
//! is a child `ra8_emulator` on the Zig core with a version-1 board profile
//! that differs from the EK profile only in its OSPI and SDRAM lines, and
//! its row comes from the child's JSON report: wall time, the CPU's stall
//! on both regions, and the external_regions counters.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("ra8_host").win32;
const external = @import("ra8_board").external.memory;
const matrix = @import("ra8_board").sizing.matrix;
const sweep = @import("ra8_board").sizing.sweep;

const ek_profile = @import("ra8_board").profile.ek_ra8d2;
const max_report_bytes = 64 * 1024 * 1024;

/// What each child run is told: the image, the part, and how the run ends
/// (a `--stop-sym` counter, or `--ms` of the image's own time).
pub const Job = struct {
    path: []const u8,
    part: []const u8 = "ra8d2",
    stop_sym: ?[]const u8 = null,
    stop_count: []const u8 = "1",
    ms: ?[]const u8 = null,
};

/// The EK profile with `config`'s OSPI, SDRAM and window lines.
pub fn profileText(out: anytype, config: external.Config) !void {
    var lines = std.mem.splitScalar(u8, ek_profile, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "ospi=")) {
            try region(out, "ospi", config.ospi);
        } else if (std.mem.startsWith(u8, line, "sdram=")) {
            try region(out, "sdram", config.sdram);
        } else if (std.mem.startsWith(u8, line, "memory_window_cycles=")) {
            try out.print("memory_window_cycles={d}\n", .{config.window_cycles});
        } else if (line.len != 0) try out.print("{s}\n", .{line});
    }
}

fn region(out: anytype, name: []const u8, one: external.RegionConfig) !void {
    try out.print("{s}=size:{d},width:{d},clock_hz:{d},latency_cycles:{d},burst:{s}\n", .{
        name, one.size, one.width, one.clock_hz, one.latency_cycles, @tagName(one.burst),
    });
}

/// One child run of `exe` on `config`, with its profile at `scratch`.
pub fn runOne(gpa: std.mem.Allocator, io: std.Io, exe: []const u8, job: Job, config: external.Config, scratch: []const u8) !sweep.Result {
    {
        const file = try std.Io.Dir.cwd().createFile(io, scratch, .{});
        defer file.close(io);
        var buffer: [1024]u8 = undefined;
        var writer = file.writerStreaming(io, &buffer);
        try profileText(&writer.interface, config);
        try writer.interface.flush();
    }
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ exe, job.path, "--cpu", "zig", "--part", job.part, "--board-profile", scratch, "--report", "json" });
    if (job.stop_sym) |name| try argv.appendSlice(gpa, &.{ "--stop-sym", name, job.stop_count });
    if (job.ms) |ms| try argv.appendSlice(gpa, &.{ "--ms", ms });
    const ran = try std.process.run(gpa, io, .{ .argv = argv.items, .stdout_limit = .limited(max_report_bytes), .stderr_limit = .limited(max_report_bytes) });
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    switch (ran.term) {
        .exited => |code| if (code != 0) return error.ChildFailed,
        else => return error.ChildFailed,
    }
    return fromReport(gpa, ran.stdout);
}

/// A row's numbers from a child's stdout: text lines, then the report.
pub fn fromReport(gpa: std.mem.Allocator, stdout: []const u8) !sweep.Result {
    const start = std.mem.indexOfScalar(u8, stdout, '{') orelse return error.NoReport;
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stdout[start..], .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    var result: sweep.Result = .{ .total_ns = try number(root.get("run"), "elapsed_cycles") };
    const regions = (root.get("memory") orelse return error.NoReport).object.get("external_regions") orelse return error.NoReport;
    for (regions.array.items) |item| {
        const name = item.object.get("name").?.string;
        const stall = try number(item.object.get("stall_cycles"), "cpu");
        result.stall_ns += stall;
        const read = try number(item, "bytes_read");
        const read_high = try number(item, "read_high_water_bytes");
        if (std.mem.eql(u8, name, "ospi")) {
            result.flash_bytes_read = read;
            result.flash_high_bytes = read_high;
        } else if (std.mem.eql(u8, name, "sdram")) {
            result.sdram_bytes_moved = read + try number(item, "bytes_written");
            result.sdram_high_bytes = @max(read_high, try number(item, "write_high_water_bytes"));
        }
    }
    return result;
}

fn number(value: ?std.json.Value, field: []const u8) !u64 {
    const object = (value orelse return error.NoReport).object;
    const got = object.get(field) orelse return error.NoReport;
    return std.math.cast(u64, got.integer) orelse error.NoReport;
}

/// Every configuration in the matrix, each judged against `target_ns`.
pub fn all(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, job: Job, target_ns: ?u64, rows: *[matrix.count]sweep.Row) !void {
    const exe = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe);
    return allWithExe(gpa, io, env, exe, job, target_ns, rows);
}

/// The same lifecycle with an explicit child, also used by embedding tests.
pub fn allWithExe(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map, exe: []const u8, job: Job, target_ns: ?u64, rows: *[matrix.count]sweep.Row) !void {
    var stops = try Stops.install();
    defer stops.restore();
    var tag: [8]u8 = undefined;
    io.random(&tag);
    const scratch = try scratchPath(gpa, env, builtin.os.tag, std.mem.readInt(u64, &tag, .little));
    defer gpa.free(scratch);
    const reserved = try reserveScratch(gpa, io, scratch);
    std.debug.print("sweep: scratch profile ready\n", .{});
    const result = runRows(gpa, io, exe, job, target_ns, rows, scratch);
    reserved.close(io);
    std.Io.Dir.cwd().deleteFile(io, scratch) catch |err| {
        if (builtin.os.tag == .windows and err == error.FileNotFound) return result;
        if (result) {} else |first| {
            std.debug.print("sweep: scratch cleanup failed: {s}\n", .{@errorName(err)});
            return first;
        }
        return err;
    };
    return result;
}

/// Exclusive reservation held through the sweep. Windows also removes the
/// file when the process terminates without running Zig cleanup.
pub fn reserveScratch(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !std.Io.File {
    if (builtin.os.tag != .windows) return std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(wide);
    const handle = win32.CreateFileW(wide, WindowsScratch.access, WindowsScratch.share, null, WindowsScratch.create_new, WindowsScratch.flags, null);
    if (handle == win32.invalid_handle) return error.ScratchCreateFailed;
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

const WindowsScratch = struct {
    // GENERIC_WRITE | DELETE, with read/write/delete sharing for children.
    pub const access = 0x40000000 | 0x00010000;
    pub const share = 7;
    pub const create_new = 1;
    // FILE_ATTRIBUTE_TEMPORARY | FILE_FLAG_DELETE_ON_CLOSE.
    pub const flags = 0x00000100 | 0x04000000;
};

fn runRows(gpa: std.mem.Allocator, io: std.Io, exe: []const u8, job: Job, target_ns: ?u64, rows: *[matrix.count]sweep.Row, scratch: []const u8) !void {
    for (rows, 0..) |*row, index| {
        if (stopping.load(.acquire)) return error.Interrupted;
        const config = matrix.at(index);
        const result = runOne(gpa, io, exe, job, config, scratch) catch |err| {
            if (stopping.load(.acquire)) return error.Interrupted;
            return err;
        };
        if (stopping.load(.acquire)) return error.Interrupted;
        const meets = if (target_ns) |target| result.total_ns <= target else true;
        row.* = .{ .config = config, .result = result, .meets = meets };
    }
}

/// Native temp conventions, ignoring empty environment values.
pub fn scratchPath(gpa: std.mem.Allocator, env: *const std.process.Environ.Map, os: std.Target.Os.Tag, tag: u64) ![]u8 {
    const name = try std.fmt.allocPrint(gpa, "ra8-sweep-{x}.board", .{tag});
    defer gpa.free(name);
    if (os == .windows) {
        const base = nonempty(env, "TMP") orelse nonempty(env, "TEMP");
        if (base) |dir| return std.fs.path.join(gpa, &.{ dir, name });
        const home = nonempty(env, "USERPROFILE") orelse return error.NoTempDirectory;
        return std.fs.path.join(gpa, &.{ home, "AppData", "Local", "Temp", name });
    }
    return std.fs.path.join(gpa, &.{ nonempty(env, "TMPDIR") orelse "/tmp", name });
}

fn nonempty(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const value = env.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

var stopping = std.atomic.Value(bool).init(false);

const Stops = struct {
    int: if (builtin.os.tag == .windows) void else std.posix.Sigaction = undefined,
    term: if (builtin.os.tag == .windows) void else std.posix.Sigaction = undefined,

    fn install() !Stops {
        stopping.store(false, .release);
        var self: Stops = .{};
        if (builtin.os.tag == .windows) {
            if (!win32.SetConsoleCtrlHandler(onConsoleStop, .TRUE).toBool()) return error.StopHandlerFailed;
        } else {
            const action: std.posix.Sigaction = .{ .handler = .{ .handler = onStop }, .mask = std.posix.sigemptyset(), .flags = 0 };
            std.posix.sigaction(std.posix.SIG.INT, &action, &self.int);
            std.posix.sigaction(std.posix.SIG.TERM, &action, &self.term);
        }
        return self;
    }

    fn restore(self: *const Stops) void {
        if (builtin.os.tag == .windows) {
            if (!win32.SetConsoleCtrlHandler(onConsoleStop, .FALSE).toBool()) std.debug.print("sweep: stop handler removal failed\n", .{});
        } else {
            std.posix.sigaction(std.posix.SIG.INT, &self.int, null);
            std.posix.sigaction(std.posix.SIG.TERM, &self.term, null);
        }
    }
};

fn onStop(_: std.posix.SIG) callconv(.c) void {
    stopping.store(true, .release);
}

fn onConsoleStop(event: win32.DWORD) callconv(.winapi) win32.BOOL {
    if (event != 0 and event != 1) return .FALSE;
    stopping.store(true, .release);
    return .TRUE;
}
