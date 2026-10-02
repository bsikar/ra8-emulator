//! The NVIC model (src/periph/nvic.zig) as the Zig core's exception source.
//! The model reads ICSR, SHPR3, ISER/ISPR and IPR through the core's own
//! bus; taking an exception clears its pending bit and sets its active bit,
//! and a return clears the active bit again.
const bus = @import("../bus.zig");
const nvic = @import("../../../periph/nvic.zig");
const nvic_clear = @import("../../../periph/nvic_clear.zig");
const Entry = @import("active.zig").Entry;
const Source = @import("source.zig").Source;

/// The bus in the shape the NVIC model's `core` parameter reads.
const Port = struct {
    through: bus.Bus,

    pub fn readWord(self: *Port, address: u32) bus.Error!u32 {
        return self.through.readWord(address);
    }

    pub fn writeWord(self: *Port, address: u32, value: u32) bus.Error!void {
        var bytes: [4]u8 = undefined;
        @import("std").mem.writeInt(u32, &bytes, value, .little);
        return self.through.write(address, &bytes);
    }
};

pub const NvicSource = struct {
    model: nvic.Nvic = .{},

    pub fn source(self: *NvicSource) Source {
        return .{ .ctx = self, .vtable = &.{ .winner = winner, .taken = taken, .returned = returned } };
    }

    fn winner(ctx: *anyopaque, through: bus.Bus) bus.Error!?Entry {
        const self: *NvicSource = @ptrCast(@alignCast(ctx));
        var port: Port = .{ .through = through };
        // Fold the write-to-clear registers first, as the model's own
        // dispatch does: on this bus they are plain memory.
        try nvic_clear.registers(&port, nvic.irq_words, nvic.clear_bits);
        const found = (try self.model.pick(&port, null)) orelse return null;
        return .{ .number = @intCast(found.number), .priority = found.priority };
    }

    fn taken(_: *anyopaque, through: bus.Bus, number: u9) bus.Error!void {
        var port: Port = .{ .through = through };
        try nvic.clearPending(&port, number);
        try nvic.setActiveBit(&port, number, true);
    }

    fn returned(_: *anyopaque, through: bus.Bus, number: u9) bus.Error!void {
        var port: Port = .{ .through = through };
        try nvic.setActiveBit(&port, number, false);
    }
};
