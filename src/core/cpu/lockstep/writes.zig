//! The stores one instruction made on the Zig core, caught on their way to
//! memory so a lockstep step can read the same bytes back from Unicorn.
const bus = @import("../bus.zig");

/// More stores than one instruction makes: STM and PUSH of every register
/// are 16 words, plus a few for FP and MVE.
pub const capacity = 32;
/// A store wider than this is kept as several chunks.
pub const widest = 8;

pub const Write = struct {
    address: u32,
    len: u8,
    bytes: [widest]u8 = undefined,

    pub fn slice(self: *const Write) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Recorder = struct {
    inner: bus.Bus,
    held: [capacity]Write = undefined,
    count: usize = 0,
    /// Set when there were more stores than `capacity`; the rest are not
    /// compared.
    dropped: bool = false,

    pub fn view(self: *Recorder) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write } };
    }

    pub fn items(self: *const Recorder) []const Write {
        return self.held[0..self.count];
    }

    pub fn record(self: *Recorder, address: u32, bytes: []const u8) void {
        if (self.count == capacity) {
            self.dropped = true;
            return;
        }
        var made: Write = .{ .address = address, .len = @intCast(bytes.len) };
        @memcpy(made.bytes[0..bytes.len], bytes);
        self.held[self.count] = made;
        self.count += 1;
    }

    fn read(ctx: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        return self.inner.read(address, into);
    }

    fn write(ctx: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        try self.inner.write(address, bytes);
        var done: usize = 0;
        while (done < bytes.len) {
            const len = @min(widest, bytes.len - done);
            self.record(address +% @as(u32, @intCast(done)), bytes[done .. done + len]);
            done += len;
        }
    }
};
