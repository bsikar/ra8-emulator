//! The memory-mapped external array the store reads and writes through (the
//! OSPI window). The core owns this contract: the part behind the window
//! implements it and the board hands it to the store, so the store never
//! imports a part.
pub const Error = error{OutOfMemory};

pub const Mapped = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resizeFn: *const fn (*anyopaque, u32) Error!void,
        readFn: *const fn (*const anyopaque, u32, []u8) bool,
        writeFn: *const fn (*anyopaque, u32, []const u8) Error!bool,
    };

    /// Size the array to the window before anything can touch it.
    pub fn resize(self: Mapped, capacity: u32) Error!void {
        return self.vtable.resizeFn(self.context, capacity);
    }

    /// False when the access runs off the array.
    pub fn read(self: Mapped, address: u32, into: []u8) bool {
        return self.vtable.readFn(self.context, address, into);
    }

    /// False when the access runs off the array.
    pub fn write(self: Mapped, address: u32, bytes: []const u8) Error!bool {
        return self.vtable.writeFn(self.context, address, bytes);
    }
};
