//! Where the core learns what is pending. The core decides whether to take
//! it; the source is told what was taken and what returned so it can keep
//! the pending and active bits the firmware reads. In a full run that is the
//! NVIC model (nvic_source.zig); in a test, whatever the test needs.
const bus = @import("../bus.zig");
const Entry = @import("active.zig").Entry;

pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        winner: *const fn (ctx: *anyopaque, through: bus.Bus) bus.Error!?Entry,
        taken: *const fn (ctx: *anyopaque, through: bus.Bus, number: u9) bus.Error!void,
        returned: *const fn (ctx: *anyopaque, through: bus.Bus, number: u9) bus.Error!void,
    };

    /// The most urgent pending, enabled exception, or null.
    pub fn winner(self: Source, through: bus.Bus) bus.Error!?Entry {
        return self.vtable.winner(self.ctx, through);
    }

    pub fn taken(self: Source, through: bus.Bus, number: u9) bus.Error!void {
        return self.vtable.taken(self.ctx, through, number);
    }

    pub fn returned(self: Source, through: bus.Bus, number: u9) bus.Error!void {
        return self.vtable.returned(self.ctx, through, number);
    }
};
