//! The extra-MRAM controller: program/erase mode, the command the sequencer
//! collected, and whether the option-setting memory is allowed to take it.
//!
//! Three windows share one model, the way one block of silicon does. The
//! MRMS program-mode registers sit at 0x4013_E000 (MSADDR, MSTATR, MENTRYR,
//! MASTAT), the MACI command-issuing port at 0x4012_0000, and the code-MRAM
//! program-control page at 0x4013_F000. The driver's sequence is MENTRYR =
//! 0xAA80 to enter program/erase mode, MSADDR = the target, the command
//! stream through the port, a poll of MSTATR for MRDY and the error mask,
//! then MENTRYR = 0xAA00 on the way out.
//!
//! Ported from board_periph_mram.c on dev, with five things that model does
//! not do.
//!
//! MSTATR IS WHAT THE SEQUENCER LEFT. dev answers every MSTATR read with
//! MRDY and nothing else, including straight after its own reject path has
//! latched ILGCOMERR and ILGLERR into the shadow. So a driver that issues an
//! illegal Program, polls MRDY and checks the error mask, which is exactly
//! the sequence dev's own header documents, reads a clean completion. Here
//! MSTATR reports the latched errors beside MRDY.
//!
//! COMMAND-LOCKED ACTUALLY LOCKS. HUM Ch 59.7.4.4 p 3590: once the
//! sequencer is command-locked, MACI commands cannot be accepted. dev
//! latches CMDLK and then runs the next command anyway. Here a command
//! arriving locked is refused and counted, and the lock is released by
//! leaving program/erase mode. That release is this model's own rule, not a
//! ported one: no opcode for Status Clear or Forced Stop is in this tree to
//! take, and a lock with no way out would hang an image rather than tell it
//! anything.
//!
//! A COMMAND NEEDS PROGRAM/ERASE MODE, AND MENTRYR NEEDS ITS KEY. dev runs
//! the command stream whether or not MENTRYR was ever written, and takes any
//! value with bit 7 set as an entry, key or no key. Both are refused and
//! counted here; the key is the 0xAA the two writes dev's own header
//! documents both carry.
//!
//! STATUS IS CONTROLLER-OWNED. dev stores any value written anywhere in the
//! window into its shadow, MSTATR and MASTAT included, so firmware can clear
//! the error bits its own illegal command raised. Refused and counted here,
//! the way this tree already treats CETCR, SRAMESR and INTS. Narrow writes
//! keep the bytes they do not name, where dev's regs[off / 4] = value wipes
//! them.
//!
//! NOT MODELLED, AND NOT GUESSED: the 0x4013_C000 wait-state and ECC
//! configuration pages, which stay sparse because ra8_cgc_init programs them
//! during clock setup with a key-strip readback this model would have to
//! invent; the erase and blank-check commands; and every MSTATR bit besides
//! MRDY and the two illegal-command latches. The code-MRAM page is carried
//! from dev unchanged: MRCPS reads idle-and-ready so the DFU program path
//! completes instead of spinning, because the mapped MRAM window already
//! takes the stores that path makes.
const std = @import("std");
const engine = @import("../core/engine.zig");
const periph = @import("registry.zig");
const maci = @import("maci.zig");
const cells = @import("mram_otp.zig");

pub const window = cells.window;

/// The MRMS program-mode sub-window (ra8_flash_regs.h). Deliberately narrow:
/// it covers only the program-mode registers, not the configuration page
/// below it.
pub const regs = struct {
    pub const base: u32 = 0x4013_E000;
    pub const span: u32 = 0x100;
    pub const off_mastat: u32 = 0x10;
    pub const off_msaddr: u32 = 0x30;
    pub const off_mstatr: u32 = 0x80;
    pub const off_mentryr: u32 = 0x84;
};

/// The MACI command-issuing area: one port, byte and halfword wide.
pub const command = struct {
    pub const base: u32 = 0x4012_0000;
    pub const span: u32 = 0x10;
};

/// The code-MRAM program-control page (the R_MRMS 0x3000 page).
pub const code_page = struct {
    pub const base: u32 = 0x4013_F000;
    pub const span: u32 = 0x100;
    pub const off_mrcps: u32 = 0x10;
    /// ABUFEMP set, nothing busy or full, no errors.
    pub const ready: u32 = 0x20;
};

pub const field = struct {
    /// MENTRYR.MENTRY, the program/erase mode status bit.
    pub const mentry: u32 = 0x0080;
    /// The key byte MENTRYR takes in its high half.
    pub const key: u32 = 0xAA00;
    pub const key_mask: u32 = 0xFF00;
    /// MSTATR.MRDY, command complete.
    pub const mrdy: u32 = 0x0000_8000;
    /// MSTATR.ILGLERR, illegal.
    pub const ilglerr: u32 = 0x0000_4000;
    /// MSTATR.ILGCOMERR, illegal command.
    pub const ilgcomerr: u32 = 0x0080_0000;
    /// MASTAT.MREAE, extra-MRAM access error.
    pub const mreae: u32 = 0x08;
    /// MASTAT.CMDLK, the command-locked state.
    pub const cmdlk: u32 = 0x10;
};

const shadow_words: usize = regs.span / 4;
const code_words: usize = code_page.span / 4;

pub const Mram = struct {
    otp: cells.Cells,
    stream: maci.Sequencer = .{},
    shadow: [shadow_words]u32 = [_]u32{0} ** shadow_words,
    code_shadow: [code_words]u32 = [_]u32{0} ** code_words,
    /// Where a program that lands is also written through, so firmware can
    /// read the option word back. A board built by a test leaves it null and
    /// the write-through is skipped; the cells still hold the program.
    memory: ?engine.Engine = null,
    /// The latched MSTATR error bits, held rather than shadowed.
    errors: u32 = 0,
    /// The latched MASTAT access bits.
    access: u32 = 0,
    msaddr: u32 = 0,
    in_pe_mode: bool = false,
    locked: bool = false,

    programs: u32 = 0,
    config_sets: u32 = 0,
    /// Commands aimed outside HUM Table 59.15's window.
    illegal: u32 = 0,
    /// Commands that arrived while the sequencer was command-locked.
    locked_out: u32 = 0,
    /// Commands that arrived without program/erase mode entered.
    outside_mode: u32 = 0,
    /// Trailers on a stream that never carried what it declared.
    malformed: u32 = 0,
    /// Programs asking a one-time-programmable cell for a bit back.
    rewrites: u32 = 0,
    /// MENTRYR writes carrying the wrong key.
    keyless: u32 = 0,
    /// Stores to MSTATR or MASTAT: firmware cannot clear its own errors.
    read_only: u32 = 0,
    /// Programs the guest memory behind the option window refused.
    faulted: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Mram {
        return .{ .otp = cells.Cells.init(allocator) };
    }

    pub fn deinit(self: *Mram) void {
        self.otp.deinit();
    }

    pub fn quiet(self: *const Mram) bool {
        return self.programs == 0 and self.config_sets == 0 and self.illegal == 0 and
            self.locked_out == 0 and self.outside_mode == 0 and self.malformed == 0 and
            self.rewrites == 0 and self.keyless == 0 and self.read_only == 0 and
            self.faulted == 0;
    }

    /// MSTATR as this model computes it: ready, plus whatever the sequencer
    /// latched.
    pub fn status(self: *const Mram) u32 {
        return field.mrdy | self.errors;
    }

    pub fn read(self: *Mram, address: u32, width: u3) u32 {
        const offset = address -% regs.base;
        if (offset >= regs.span) return 0;
        const byte = offset % 4;
        return switch (offset & ~@as(u32, 3)) {
            regs.off_mentryr => part_of(if (self.in_pe_mode) field.mentry else 0, byte, width),
            regs.off_mstatr => part_of(self.status(), byte, width),
            regs.off_mastat => part_of(self.access, byte, width),
            else => part_of(self.shadow[offset / 4], byte, width),
        };
    }

    pub fn write(self: *Mram, address: u32, width: u3, value: u32) void {
        const offset = address -% regs.base;
        if (offset >= regs.span) return;
        const byte = offset % 4;
        switch (offset & ~@as(u32, 3)) {
            regs.off_mstatr, regs.off_mastat => self.read_only +%= 1,
            regs.off_mentryr => self.enter(offset, byte, width, value),
            regs.off_msaddr => self.msaddr = self.store(offset, byte, width, value),
            else => _ = self.store(offset, byte, width, value),
        }
    }

    /// The MACI port. A halfword is payload; a byte is a command step.
    pub fn commandWrite(self: *Mram, width: u3, value: u32) void {
        if (width == 2) {
            self.stream.halfwordWritten(@truncate(value));
            return;
        }
        if (self.stream.byteWritten(@truncate(value)) != .commit) return;
        self.run();
        self.stream.reset();
    }

    pub fn codeRead(self: *Mram, address: u32, width: u3) u32 {
        const at = address -% code_page.base;
        if (at >= code_page.span) return 0;
        const byte = at % 4;
        if (at & ~@as(u32, 3) == code_page.off_mrcps) return part_of(code_page.ready, byte, width);
        return part_of(self.code_shadow[at / 4], byte, width);
    }

    pub fn codeWrite(self: *Mram, address: u32, width: u3, value: u32) void {
        const at = address -% code_page.base;
        if (at >= code_page.span) return;
        const word = at / 4;
        self.code_shadow[word] = merge(self.code_shadow[word], at % 4, width, value);
    }

    /// MENTRYR. The key has to be there, and leaving program/erase mode is
    /// what releases a command-locked sequencer.
    fn enter(self: *Mram, offset: u32, byte: u32, width: u3, value: u32) void {
        const word = offset / 4;
        const merged = merge(self.shadow[word], byte, width, value);
        if (merged & field.key_mask != field.key) {
            self.keyless +%= 1;
            return;
        }
        self.shadow[word] = merged;
        self.in_pe_mode = merged & field.mentry != 0;
        if (self.in_pe_mode) return;
        self.locked = false;
        self.errors = 0;
        self.access = 0;
    }

    /// Run the command the trailer just started.
    fn run(self: *Mram) void {
        if (self.locked) {
            self.locked_out +%= 1;
            return;
        }
        if (!self.in_pe_mode) {
            self.outside_mode +%= 1;
            return;
        }
        if (!self.stream.complete()) {
            self.malformed +%= 1;
            return;
        }
        const payload = self.stream.bytes();
        if (!window.holds(self.msaddr, payload.len)) return self.reject();
        if (self.otp.rewrites(self.msaddr, payload)) {
            self.rewrites +%= 1;
            return;
        }
        self.commit(payload);
    }

    /// Program the payload into the cells, and through to guest memory so a
    /// read-back of the option word sees it.
    fn commit(self: *Mram, payload: []const u8) void {
        self.otp.program(self.msaddr, payload) catch {
            self.faulted +%= 1;
            return;
        };
        if (self.memory) |memory| {
            memory.write(self.msaddr, payload) catch {
                self.faulted +%= 1;
                return;
            };
        }
        switch (self.stream.kind) {
            .program => self.programs +%= 1,
            .config_set => self.config_sets +%= 1,
        }
    }

    /// The command-locked state a rejection leaves behind, in the bits a
    /// by-hand reproduction on an EK-RA8D2 reports: MSTATR 0x0080C000,
    /// MASTAT 0x18.
    fn reject(self: *Mram) void {
        self.errors |= field.ilgcomerr | field.ilglerr;
        self.access |= field.cmdlk | field.mreae;
        self.locked = true;
        self.illegal +%= 1;
    }

    fn store(self: *Mram, offset: u32, byte: u32, width: u3, value: u32) u32 {
        const word = offset / 4;
        self.shadow[word] = merge(self.shadow[word], byte, width, value);
        return self.shadow[word];
    }

    /// Put every window the option memory answers for on the bus, and hand
    /// it the machine a landed program is written through to.
    pub fn attach(self: *Mram, bus: *periph.Bus, machine: engine.Engine) periph.Error!void {
        self.memory = machine;
        try bus.add(self.block());
        try bus.add(self.commandBlock());
        try bus.add(self.codeBlock());
    }

    pub fn block(self: *Mram) periph.Block {
        return .{
            .name = "MRAM",
            .base = regs.base,
            .size = regs.span,
            .context = self,
            .readFn = readThunk,
            .writeFn = writeThunk,
        };
    }

    pub fn commandBlock(self: *Mram) periph.Block {
        return .{
            .name = "MACI",
            .base = command.base,
            .size = command.span,
            .context = self,
            .readFn = commandReadThunk,
            .writeFn = commandWriteThunk,
        };
    }

    pub fn codeBlock(self: *Mram) periph.Block {
        return .{
            .name = "MRAM-pgm",
            .base = code_page.base,
            .size = code_page.span,
            .context = self,
            .readFn = codeReadThunk,
            .writeFn = codeWriteThunk,
        };
    }
};

fn widthMask(width: u3) u32 {
    return switch (width) {
        1 => 0xFF,
        2 => 0xFFFF,
        else => 0xFFFF_FFFF,
    };
}

/// The part of a 32-bit register a narrow access names.
fn part_of(value: u32, byte_offset: u32, width: u3) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    return (value >> shift) & widthMask(width);
}

/// Fold a narrow write into a 32-bit register, leaving the bytes the access
/// does not name where they were.
fn merge(current: u32, byte_offset: u32, width: u3, value: u32) u32 {
    if (width >= 4) return value;
    const shift: u5 = @intCast(byte_offset * 8);
    const bits = widthMask(width);
    const slot: u32 = bits << shift;
    return (current & ~slot) | ((value & bits) << shift);
}

fn readThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Mram = @ptrCast(@alignCast(context));
    return self.read(address, width);
}

fn writeThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Mram = @ptrCast(@alignCast(context));
    self.write(address, width, value);
}

/// The port answers zero: the result of a command is in MSTATR, not here.
fn commandReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    _ = context;
    _ = address;
    _ = width;
    return 0;
}

fn commandWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    _ = address;
    const self: *Mram = @ptrCast(@alignCast(context));
    self.commandWrite(width, value);
}

fn codeReadThunk(context: *anyopaque, address: u32, width: u3) u32 {
    const self: *Mram = @ptrCast(@alignCast(context));
    return self.codeRead(address, width);
}

fn codeWriteThunk(context: *anyopaque, address: u32, width: u3, value: u32) void {
    const self: *Mram = @ptrCast(@alignCast(context));
    self.codeWrite(address, width, value);
}
