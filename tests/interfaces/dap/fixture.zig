//! A bare Session for scripted DAP conversations, with observable CPU state.
const std = @import("std");
const ra8 = @import("ra8");
const bus = ra8.chip.core.cpu.bus;
pub const Fixture = struct {
    bytes: [128]u8 = @splat(0),
    cpu: ra8.chip.core.cpu.cpu.Cpu = undefined,
    machine: ra8.session.stop_machine.Machine = .{},
    session: ra8.session.api.Session = undefined,
    adapter: ra8.dap.adapter.Adapter = undefined,

    pub fn init(self: *Fixture) !void {
        self.bytes[0..8].* = .{ 128, 0, 0, 0, 9, 0, 0, 0 };
        self.bytes[8..16].* = .{ 0, 0xbf, 0, 0xbf, 0xfe, 0xe7, 0x80, 0xba };
        self.cpu = .{ .bus = .{ .ctx = self, .vtable = &.{ .read = read, .write = write } } };
        try self.cpu.reset(0);
        self.session = .{ .live = .{ .core = .{ .cpu = &self.cpu }, .machine = &self.machine, .budget = 100 } };
        self.adapter = .{ .allocator = std.testing.allocator, .target = .{ .session = &self.session } };
    }
    pub fn deinit(self: *Fixture) void {
        self.adapter.deinit();
    }
    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (@as(u64, address) + into.len > self.bytes.len) return error.Unmapped;
        @memcpy(into, self.bytes[address..][0..into.len]);
    }
    fn write(ctx: *anyopaque, address: u32, from: []const u8) bus.Error!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (@as(u64, address) + from.len > self.bytes.len) return error.Unmapped;
        @memcpy(self.bytes[address..][0..from.len], from);
    }
};

pub fn send(adapter: *ra8.dap.adapter.Adapter, json: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try adapter.request(json, &out.writer);
    return std.testing.allocator.dupe(u8, out.written());
}
pub fn expectSend(adapter: *ra8.dap.adapter.Adapter, json: []const u8, expected: []const u8) !void {
    const got = try send(adapter, json);
    defer std.testing.allocator.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, expected) != null);
}
pub fn connect(adapter: *ra8.dap.adapter.Adapter) !void {
    try expectSend(adapter,
        \\{"seq":1,"type":"request","command":"initialize","arguments":{}}
    , "\"success\":true");
    try expectSend(adapter,
        \\{"seq":2,"type":"request","command":"attach","arguments":{}}
    , "\"success\":true");
    try expectSend(adapter,
        \\{"seq":3,"type":"request","command":"configurationDone"}
    , "\"reason\":\"entry\"");
}
