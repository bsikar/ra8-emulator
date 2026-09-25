//! The Unicorn engine, wrapped once so nothing above it touches C.
//!
//! Unicorn stays a C library: this is the boundary, and with src/c.zig it is
//! the only place that handles uc_err, raw pointers or C integer types.
//! Callers get Zig errors, slices and named registers.
const std = @import("std");
const c = @import("c.zig");
const elf = @import("elf.zig");
const memmap = @import("memmap.zig");
const periph = @import("periph.zig");
const disasm = @import("disasm.zig");

pub const Error = error{
    OpenFailed,
    MapFailed,
    AttachFailed,
    WriteFailed,
    RegisterFailed,
    RunFailed,
};

pub const Fault = struct {
    pc: u32,
    detail: []const u8,
    /// The access that took the fault, when Unicorn reported one.
    access: ?Access = null,
    /// The instruction at the PC, when it decoded.
    instruction: ?disasm.Text = null,

    pub const Access = struct {
        kind: enum { read, write, fetch },
        address: u64,
        size: u8,
        value: u64,
    };
};

/// Catches the invalid access behind a fault. Unicorn reports the address and
/// width in a hook and only the error code afterwards, so the hook writes here
/// and `run` reads it back once the run has stopped.
pub const Watch = struct {
    last: ?Fault.Access = null,

    pub fn clear(self: *Watch) void {
        self.last = null;
    }
};

pub const Cortex = enum(c_int) {
    pc = c.uc.UC_ARM_REG_PC,
    sp = c.uc.UC_ARM_REG_SP,
    lr = c.uc.UC_ARM_REG_LR,
    r0 = c.uc.UC_ARM_REG_R0,
    r1 = c.uc.UC_ARM_REG_R1,
    r2 = c.uc.UC_ARM_REG_R2,
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
        return self.mapWithPerms(base, size, .{});
    }

    pub fn mapWithPerms(self: Engine, base: u32, size: u32, perms: memmap.Region.Perms) Error!void {
        var prot: c_uint = 0;
        if (perms.read) prot |= c.uc.UC_PROT_READ;
        if (perms.write) prot |= c.uc.UC_PROT_WRITE;
        if (perms.exec) prot |= c.uc.UC_PROT_EXEC;
        if (c.uc.uc_mem_map(self.handle, base, size, prot) != c.uc.UC_ERR_OK) {
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
        for (memmap.ram) |region| try self.mapWithPerms(region.base, region.size, region.perms);
    }

    /// Put the peripheral bus behind the peripheral window and its Non-secure
    /// alias. Until this runs, the first store a driver makes to a peripheral
    /// register is an unmapped write and the run ends there; after it, every
    /// access in the window reaches the bus and either a modelled block or the
    /// sparse register file answers it.
    pub fn attachPeriph(self: Engine, bus: *periph.Bus) Error!void {
        for ([_]u32{ periph.base, periph.ns_base }) |window| {
            if (c.uc.uc_mmio_map(
                self.handle,
                window,
                periph.size,
                onRead,
                bus,
                onWrite,
                bus,
            ) != c.uc.UC_ERR_OK) {
                return Error.AttachFailed;
            }
        }
    }

    /// Record the invalid accesses a run takes. Without this a fault is just
    /// an error code and a PC; with it the report can say which address the
    /// firmware reached for and how wide the access was.
    pub fn attachWatch(self: Engine, watch: *Watch) Error!void {
        var hook: c.uc.uc_hook = 0;
        if (c.uc.uc_hook_add(
            self.handle,
            &hook,
            c.uc.UC_HOOK_MEM_INVALID,
            @constCast(@as(*const anyopaque, @ptrCast(&onInvalid))),
            watch,
            1,
            0,
        ) != c.uc.UC_ERR_OK) {
            return Error.AttachFailed;
        }
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
    pub fn run(self: Engine, start: u32, instructions: usize, watch: ?*Watch) Error!?Fault {
        if (watch) |w| w.clear();
        const err = c.uc.uc_emu_start(self.handle, start | 1, 0xFFFF_FFFF, 0, instructions);
        if (err == c.uc.UC_ERR_OK) return null;
        const pc = self.register(.pc) catch 0;
        var bytes: [4]u8 = undefined;
        return Fault{
            .pc = pc,
            .detail = std.mem.span(c.uc.uc_strerror(err)),
            .access = if (watch) |w| w.last else null,
            .instruction = blk: {
                self.read(pc, &bytes) catch break :blk null;
                break :blk disasm.one(pc, &bytes) catch null;
            },
        };
    }
};

/// Unicorn hands an offset inside the mapped window, so the window base is
/// added back before the bus sees it. These two functions and src/c.zig are
/// the only places with a C calling convention in the emulator.
fn onRead(uc: ?*c.uc.uc_engine, offset: u64, size: c_uint, user: ?*anyopaque) callconv(.C) u64 {
    _ = uc;
    const bus: *periph.Bus = @ptrCast(@alignCast(user.?));
    return bus.read(periph.base + @as(u32, @truncate(offset)), widthOf(size));
}

fn onWrite(uc: ?*c.uc.uc_engine, offset: u64, size: c_uint, value: u64, user: ?*anyopaque) callconv(.C) void {
    _ = uc;
    const bus: *periph.Bus = @ptrCast(@alignCast(user.?));
    bus.write(periph.base + @as(u32, @truncate(offset)), widthOf(size), @truncate(value));
}

fn onInvalid(
    uc: ?*c.uc.uc_engine,
    kind: c_int,
    address: u64,
    size: c_int,
    value: i64,
    user: ?*anyopaque,
) callconv(.C) bool {
    _ = uc;
    const watch: *Watch = @ptrCast(@alignCast(user.?));
    watch.last = .{
        .kind = switch (kind) {
            c.uc.UC_MEM_WRITE_UNMAPPED, c.uc.UC_MEM_WRITE_PROT => .write,
            c.uc.UC_MEM_FETCH_UNMAPPED, c.uc.UC_MEM_FETCH_PROT => .fetch,
            else => .read,
        },
        .address = address,
        .size = @intCast(size),
        .value = @bitCast(value),
    };
    // false: do not pretend the access succeeded, let the run stop.
    return false;
}

fn widthOf(size: c_uint) u3 {
    return switch (size) {
        1 => 1,
        2 => 2,
        else => 4,
    };
}

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

test "with the bus attached, a store into peripheral space is serviced" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();

    var bus = periph.Bus.init(std.testing.allocator);
    defer bus.deinit();
    try engine.attachPeriph(&bus);

    // r0 = 0x40000000; store a byte-sized constant there and read it back.
    const code = [_]u8{
        0x40, 0xF2, 0x00, 0x00, // movw r0, #0
        0xC4, 0xF2, 0x00, 0x00, // movt r0, #0x4000
        0x55, 0x21, //             movs r1, #0x55
        0x01, 0x60, //             str  r1, [r0]
        0x02, 0x68, //             ldr  r2, [r0]
    };
    try engine.write(memmap.sram_base, &code);
    try engine.setRegister(.sp, memmap.sram_base + 0x1000);
    const fault = try engine.run(memmap.sram_base, 5, null);
    try std.testing.expect(fault == null);
    try std.testing.expect(bus.counters.writes >= 1);
    try std.testing.expectEqual(@as(u32, 0x55), bus.read(periph.base, 4));
    try std.testing.expectEqual(@as(u32, 0x55), try engine.register(.r2));
}

test "a fault reports the address it reached for and the instruction that did it" {
    var engine = try Engine.open();
    defer engine.close();
    try engine.mapBoardRam();

    var watch = Watch{};
    try engine.attachWatch(&watch);

    // r0 = 0x90000000 (nothing is mapped there); str r1, [r0].
    const code = [_]u8{
        0x40, 0xF2, 0x00, 0x00, // movw r0, #0
        0xC9, 0xF2, 0x00, 0x00, // movt r0, #0x9000
        0x55, 0x21, //             movs r1, #0x55
        0x01, 0x60, //             str  r1, [r0]
    };
    try engine.write(memmap.sram_base, &code);
    try engine.setRegister(.sp, memmap.sram_base + 0x1000);

    const fault = (try engine.run(memmap.sram_base, 4, &watch)) orelse return error.TestExpectedFault;
    const access = fault.access orelse return error.TestExpectedAccess;
    try std.testing.expectEqual(@as(u64, 0x9000_0000), access.address);
    try std.testing.expectEqual(@as(u8, 4), access.size);
    try std.testing.expect(access.kind == .write);
    try std.testing.expectEqualStrings("str r1, [r0]", (fault.instruction orelse return error.TestExpectedText).slice());
}
