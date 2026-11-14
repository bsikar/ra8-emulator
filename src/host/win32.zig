//! Win32 calls the Windows arms need that Zig 0.17's std no longer exports
//! (RA8EMU-827). Kept in one place so each Windows arm declares nothing itself.
const std = @import("std");
const windows = std.os.windows;

pub const HANDLE = windows.HANDLE;
pub const DWORD = windows.DWORD;
pub const BOOL = windows.BOOL;
pub const invalid_handle = windows.INVALID_HANDLE_VALUE;

/// GetStdHandle selectors for the process's stdin and stdout.
pub const std_input: DWORD = @bitCast(@as(i32, -10));
pub const std_output: DWORD = @bitCast(@as(i32, -11));

pub extern "kernel32" fn GetStdHandle(which: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, security: ?*anyopaque, size: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: DWORD, share: DWORD, security: ?*anyopaque, creation: DWORD, flags: DWORD, template: ?HANDLE) callconv(.winapi) HANDLE;
pub extern "kernel32" fn ReadFile(file: HANDLE, into: [*]u8, len: DWORD, read: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(file: HANDLE, from: [*]const u8, len: DWORD, written: ?*DWORD, overlapped: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn PeekNamedPipe(pipe: HANDLE, into: ?*anyopaque, len: DWORD, read: ?*DWORD, available: ?*DWORD, left: ?*DWORD) callconv(.winapi) BOOL;

/// The process's own std handle, or `invalid_handle` when it has none.
pub fn stdHandle(which: DWORD) HANDLE {
    return GetStdHandle(which) orelse invalid_handle;
}

/// Bytes waiting in a pipe; null once the pipe has broken or is not a pipe.
pub fn pipeWaiting(pipe: HANDLE) ?DWORD {
    var available: DWORD = 0;
    if (!PeekNamedPipe(pipe, null, 0, null, &available, null).toBool()) return null;
    return available;
}

/// WSAPOLLFD, and the WSAPoll bits the serve front asks for (RA8EMU-828).
pub const PollFd = extern struct { fd: HANDLE, events: i16, revents: i16 };
pub const poll_in: i16 = 0x0300;
pub const poll_out: i16 = 0x0010;
pub const poll_hup: i16 = 0x0002;
pub const poll_err: i16 = 0x0001;
pub const msg_peek: c_int = 0x2;
pub const wsa_would_block: c_int = 10035;

pub extern "ws2_32" fn WSAPoll(fds: [*]PollFd, count: c_ulong, timeout_ms: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn send(socket: HANDLE, from: [*]const u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn recv(socket: HANDLE, into: [*]u8, len: c_int, flags: c_int) callconv(.winapi) c_int;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;
pub const CtrlHandler = *const fn (event: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleCtrlHandler(handler: ?CtrlHandler, add: BOOL) callconv(.winapi) BOOL;
pub extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;

pub const ProcessInfo = extern struct { process: HANDLE, thread: HANDLE, process_id: DWORD, thread_id: DWORD };
pub extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, command: [*:0]u16, process_security: ?*anyopaque, thread_security: ?*anyopaque, inherit: BOOL, flags: DWORD, environment: ?*anyopaque, cwd: ?[*:0]const u16, startup: *windows.STARTUPINFOW, info: *ProcessInfo) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetHandleInformation(handle: HANDLE, mask: DWORD, flags: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetProcessId(handle: HANDLE) callconv(.winapi) DWORD;
pub extern "kernel32" fn AttachConsole(process_id: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
pub extern "kernel32" fn GenerateConsoleCtrlEvent(event: DWORD, group: DWORD) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateJobObjectW(security: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: c_int, info: *const anyopaque, length: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateJobObject(job: HANDLE, code: DWORD) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetComputerNameW(name: [*]u16, length: *DWORD) callconv(.winapi) BOOL;

/// Win32 JOBOBJECT_EXTENDED_LIMIT_INFORMATION (information class 9).
pub const JobLimits = extern struct {
    basic: extern struct {
        process_time: i64 = 0,
        job_time: i64 = 0,
        flags: DWORD = 0,
        min_working_set: usize = 0,
        max_working_set: usize = 0,
        active_processes: DWORD = 0,
        affinity: usize = 0,
        priority: DWORD = 0,
        scheduling: DWORD = 0,
    } = .{},
    io_counters: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};
