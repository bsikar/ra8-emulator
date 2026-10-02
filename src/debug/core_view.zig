//! One core as the debugger reads it, whichever CPU runs it (RA8EMU-105):
//! the Unicorn engine or the Zig core behind src/debug/zig_core.zig. The
//! session and its views read registers and memory through this, so the
//! same commands work on `--cpu unicorn` and `--cpu zig`.
const engine = @import("../core/engine.zig");
const bus = @import("../core/cpu/bus.zig");
const zig_core = @import("zig_core.zig");

pub const Cortex = engine.Cortex;
pub const Error = engine.Error || bus.Error;

pub const View = union(enum) {
    unicorn: *const engine.Engine,
    zig: zig_core.ZigCore,

    pub fn register(self: View, which: Cortex) Error!u32 {
        return switch (self) {
            .unicorn => |core| core.register(which),
            .zig => |core| core.register(which),
        };
    }

    pub fn setRegister(self: View, which: Cortex, value: u32) Error!void {
        switch (self) {
            .unicorn => |core| try core.setRegister(which, value),
            .zig => |core| core.setRegister(which, value),
        }
    }

    pub fn read(self: View, address: u32, into: []u8) Error!void {
        return switch (self) {
            .unicorn => |core| core.read(address, into),
            .zig => |core| core.read(address, into),
        };
    }

    pub fn readWord(self: View, address: u32) Error!u32 {
        return switch (self) {
            .unicorn => |core| core.readWord(address),
            .zig => |core| core.readWord(address),
        };
    }

    pub fn write(self: View, address: u32, bytes: []const u8) Error!void {
        return switch (self) {
            .unicorn => |core| core.write(address, bytes),
            .zig => |core| core.write(address, bytes),
        };
    }
};
