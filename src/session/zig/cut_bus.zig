//! Observe SysTick stores while retaining the existing bus capabilities.
const bus = @import("ra8_chip").core.cpu.bus;
const Cut = @import("ra8_chip").core.cpu.cpu.systick_cut.Cut;

pub const CutBus = struct {
    inner: bus.Bus,
    cut: *Cut,

    pub fn view(self: *CutBus) bus.Bus {
        return .{ .ctx = self, .vtable = &.{ .read = read, .write = write, .latch = latch, .repeat = repeat, .peek = peek } };
    }

    fn read(context: *anyopaque, address: u32, into: []u8) bus.Error!void {
        const self: *CutBus = @ptrCast(@alignCast(context));
        return self.inner.read(address, into);
    }

    fn write(context: *anyopaque, address: u32, bytes: []const u8) bus.Error!void {
        const self: *CutBus = @ptrCast(@alignCast(context));
        try self.cut.see(self.inner, address, bytes);
        return self.inner.write(address, bytes);
    }

    fn latch(context: *anyopaque, address: u32, bits: u32) bus.Error!void {
        const self: *CutBus = @ptrCast(@alignCast(context));
        return self.inner.latch(address, bits);
    }

    fn repeat(context: *anyopaque, address: u32, len: usize, times: u64) bool {
        const self: *CutBus = @ptrCast(@alignCast(context));
        return self.inner.repeat(address, len, times);
    }

    fn peek(context: *anyopaque, address: u32, into: []u8) bool {
        const self: *CutBus = @ptrCast(@alignCast(context));
        return self.inner.peek(address, into);
    }
};
