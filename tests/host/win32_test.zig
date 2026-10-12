const std = @import("std");
const win32 = @import("ra8").host.win32;

// Io.net owns AFD handles on Zig 0.17 Windows. These boundary calls need
// actual Winsock sockets, so this fixture creates both ends through ws2_32.
const Sockets = if (@import("builtin").os.tag == .windows) struct {
    const Address = extern struct { family: u16 = 2, port: u16 = 0, address: u32 = std.mem.nativeToBig(u32, 0x7f00_0001), zero: [8]u8 = @splat(0) };
    extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) c_int;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) c_int;
    extern "ws2_32" fn socket(family: c_int, kind: c_int, protocol: c_int) callconv(.winapi) win32.HANDLE;
    extern "ws2_32" fn bind(fd: win32.HANDLE, address: *const Address, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn getsockname(fd: win32.HANDLE, address: *Address, len: *c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn listen(fd: win32.HANDLE, backlog: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn connect(fd: win32.HANDLE, address: *const Address, len: c_int) callconv(.winapi) c_int;
    extern "ws2_32" fn accept(fd: win32.HANDLE, address: ?*Address, len: ?*c_int) callconv(.winapi) win32.HANDLE;
    extern "ws2_32" fn closesocket(fd: win32.HANDLE) callconv(.winapi) c_int;

    fn pair() ![2]win32.HANDLE {
        var data: [512]u8 align(8) = undefined;
        try std.testing.expectEqual(@as(c_int, 0), WSAStartup(0x0202, &data));
        errdefer _ = WSACleanup();
        const server = socket(2, 1, 0);
        try std.testing.expect(server != win32.invalid_handle);
        defer _ = closesocket(server);
        var address: Address = .{};
        try std.testing.expectEqual(@as(c_int, 0), bind(server, &address, @sizeOf(Address)));
        var size: c_int = @sizeOf(Address);
        try std.testing.expectEqual(@as(c_int, 0), getsockname(server, &address, &size));
        try std.testing.expectEqual(@as(c_int, 0), listen(server, 1));
        const client = socket(2, 1, 0);
        try std.testing.expect(client != win32.invalid_handle);
        errdefer _ = closesocket(client);
        try std.testing.expectEqual(@as(c_int, 0), connect(client, &address, size));
        const peer = accept(server, null, null);
        try std.testing.expect(peer != win32.invalid_handle);
        return .{ client, peer };
    }
} else struct {};

test "std handle selectors match STD_INPUT_HANDLE and STD_OUTPUT_HANDLE" {
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF6), win32.std_input);
    try std.testing.expectEqual(@as(u32, 0xFFFF_FFF5), win32.std_output);
}

test "the Windows socket boundary sends bytes and reports peer closure" {
    if (@import("builtin").os.tag != .windows) return;
    const ends = try Sockets.pair();
    defer _ = Sockets.WSACleanup();
    defer _ = Sockets.closesocket(ends[1]);
    var client_open = true;
    defer if (client_open) {
        _ = Sockets.closesocket(ends[0]);
    };
    try std.testing.expectEqual(@as(c_int, 4), win32.send(ends[0], "ping", 4, 0));
    var bytes: [4]u8 = undefined;
    var count: usize = 0;
    while (count < bytes.len) {
        const got = win32.recv(ends[1], bytes[count..].ptr, @intCast(bytes.len - count), 0);
        try std.testing.expect(got > 0);
        count += @intCast(got);
    }
    try std.testing.expectEqualStrings("ping", &bytes);
    _ = Sockets.closesocket(ends[0]);
    client_open = false;
    try std.testing.expectEqual(@as(c_int, 0), win32.recv(ends[1], &bytes, bytes.len, 0));
}
