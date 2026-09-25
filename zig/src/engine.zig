//! The Unicorn engine, wrapped once so nothing above it touches C.
//!
//! Unicorn stays a C library: this is the boundary, and it is the only place
//! in the rewrite that handles uc_err, raw pointers or C integer types.
//! Callers get Zig errors, slices and named registers.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const memmap = @import("memmap.zig");

pub const Error = error{
    OpenFailed,
    MapFailed,
    WriteFailed,
    RegisterFailed,
    RunFailed,
};

pub const Fault = struct {
    pc: u32,
    detail: []const u8,
};

pub const Cortex = enum(c_int) {
    pc = c.uc.UC_ARM_REG_PC,
    sp = c.uc.UC_ARM_REG_SP,
    lr = c.uc.UC_ARM_REG_LR,
};

pub const Engine = struct {
    handle: ?*c.uc.uc_engine,

    pub fn open() Error!Engine {
        var handle: ?*c.uc.uc_engine = null;
        // Cortex-M85 is the RA8D2 core; Unicorn models it as an ARM MCLASS CPU.
        if (c.uc.uc_open(c.uc.UC_ARCH_ARM, c.uc.UC_MODE_THUMB | c.uc.UC_MODE_MCLASS, &handle) != c.uc.UC_ERR_OK) {
            return Error.OpenFailed;
        }
        return .{ .handle = handle };
    }

    pub fn close(self: *Engine) void {
        if (self.handle) |handle| _ = c.uc.uc_close(handle);
        self.handle = null;
    }

    pub fn map(self: Engine, base: u32, size: u32) Error!void {
        if (c.uc.uc_mem_map(self.handle, base, size, c.uc.UC_PROT_ALL) != c.uc.UC_ERR_OK) {
            return Error.MapFailed;
        }
    }

    pub fn write(self: Engine, address: u32, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        if (c.uc.uc_mem_write(self.handle, address, bytes.ptr, bytes.len) != c.uc.UC_ERR_OK) {
            return Error.WriteFailed;
        }
    }

    pub fn read(self: Engine, address: u32, into: []u8) Error!void {
        if (into.len == 0) return;
        if (c.uc.uc_mem_read(self.handle, address, into.ptr, into.len) != c.uc.UC_ERR_OK) {
            return Error.WriteFailed;
        }
    }

    pub fn readWord(self: Engine, address: u32) Error!u32 {
        var bytes: [4]u8 = undefined;
        try self.read(address, &bytes);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn setRegister(self: Engine, which: Cortex, value: u32) Error!void {
        var scratch = value;
        if (c.uc.uc_reg_write(self.handle, @intFromEnum(which), &scratch) != c.uc.UC_ERR_OK) {
            return Error.RegisterFailed;
        }
    }

    pub fn register(self: Engine, which: Cortex) Error!u32 {
        var value: u32 = 0;
        if (c.uc.uc_reg_read(self.handle, @intFromEnum(which), &value) != c.uc.UC_ERR_OK) {
            return Error.RegisterFailed;
        }
        return value;
    }

    /// Map the RAM regions the board has before any image lands in them.
    pub fn mapBoardRam(self: Engine) Error!void {
        for (memmap.ram) |region| try self.map(region.base, region.size);
    }

    /// Stream every PT_LOAD segment to its load address, mapping the flash-like
    /// pages the image asks for that the board map does not already cover.
    pub fn loadImage(self: Engine, image: elf.Image) Error!u32 {
        var mapped_low: u64 = 0;
        var mapped_high: u64 = 0;
        var written: u32 = 0;
        var index: u16 = 0;
        while (index < image.segmentCount()) : (index += 1) {
            const segment = image.loadSegment(index) orelse continue;
            const page_base = segment.paddr & ~@as(u32, 0xFFF);
            const span = (@as(u64, segment.paddr) + @max(segment.memsz, @as(u32, @intCast(segment.bytes.len)))) - page_base;
            const page_size: u32 = @intCast((span + 0xFFF) & ~@as(u64, 0xFFF));
            if (!coveredByBoard(page_base, page_size) and
                !(page_base >= mapped_low and @as(u64, page_base) + page_size <= mapped_high))
            {
                try self.map(page_base, page_size);
                mapped_low = page_base;
                mapped_high = @as(u64, page_base) + page_size;
            }
            try self.write(segment.paddr, segment.bytes);
            written += @intCast(segment.bytes.len);
        }
        if (written == 0) return Error.WriteFailed;
        return written;
    }

    /// Reset the core the way the silicon does: SP and PC out of the vector
    /// table, PC with the Thumb bit stripped.
    pub fn resetFromVectorTable(self: Engine, vector_base: u32) Error!void {
        const stack_pointer = try self.readWord(vector_base);
        const reset_vector = try self.readWord(vector_base + 4);
        try self.setRegister(.sp, stack_pointer);
        try self.setRegister(.pc, reset_vector & ~@as(u32, 1));
    }

    /// Run a bounded number of instructions. A fault is a result, not a crash:
    /// it comes back with the PC that took it.
    pub fn run(self: Engine, start: u32, instructions: usize) Error!?Fault {
        const err = c.uc.uc_emu_start(self.handle, start | 1, 0xFFFF_FFFF, 0, instructions);
        if (err == c.uc.UC_ERR_OK) return null;
        return Fault{
            .pc = self.register(.pc) catch 0,
            .detail = std.mem.span(c.uc.uc_strerror(err)),
        };
    }
};

fn coveredByBoard(base: u32, size: u32) bool {
    for (memmap.ram) |region| {
        if (base >= region.base and @as(u64, base) + size <= region.end()) return true;
    }
    return false;
}

test "an engine opens, maps the board, and reads back what it wrote" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();
    try engine.write(memmap.sram_base, &[_]u8{ 0x0D, 0xF0, 0xAD, 0x0B });
    try std.testing.expectEqual(@as(u32, 0x0BADF00D), try engine.readWord(memmap.sram_base));
    try engine.setRegister(.sp, memmap.sram_base + 0x100);
    try std.testing.expectEqual(memmap.sram_base + 0x100, try engine.register(.sp));
}
