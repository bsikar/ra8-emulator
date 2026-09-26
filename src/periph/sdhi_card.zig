//! The SD card on the other side of the host controller: what it holds, and
//! which state it is in when a command arrives.
//!
//! Split out of sdhi.zig because the two answer different questions. The
//! controller owns a register window, a FIFO and a set of status flags; the
//! card owns 512-byte blocks, a relative address, and the five-state walk
//! the SD Physical Layer puts it through before a block command means
//! anything: idle -> ready -> ident -> stby -> tran.
//!
//! The store is sparse, the same shape xspi_flash.zig takes: a block is held
//! from the first time something writes to it, and a block nobody has
//! written reads as zeros, which is what a freshly formatted card gives.
//! dev shares a real `--sd` image with board_periph_sd.c; that file is not
//! ported yet, so the card here is RAM-backed and its capacity is the
//! model's own choice, stated below rather than implied.
const std = @import("std");

pub const geometry = struct {
    /// The SD block size every command here works in.
    pub const block_bytes: u32 = 512;
    /// CSD v2 counts capacity in units of 1024 blocks.
    pub const csize_unit: u32 = 1024;
    /// The model's own capacity, 32 MiB, picked so C_SIZE is exact and a
    /// filesystem image has somewhere to go. Nothing in the tree fixes it.
    pub const capacity_blocks: u32 = 64 * 1024;
};

/// What a card answers with. The controller drops these into SD_RSP10..76.
pub const response = struct {
    /// R1: TRAN state, ready for data.
    pub const r1_ready: u32 = 0x0000_0900;
    /// R1 bit 5, APP_CMD accepted, so the ACMD that follows is honoured.
    pub const r1_app_cmd: u32 = 0x0000_0020;
    /// R1 bit 22, ILLEGAL_COMMAND: the card understood the command and
    /// refused it in this state.
    pub const r1_illegal: u32 = 0x0040_0000;
    /// R7 for CMD8: 2.7-3.6V plus the 0xAA check pattern echoed back.
    pub const r7_if_cond: u32 = 0x0000_01AA;
    /// R3 for ACMD41: power-up done, CCS set (SDHC/SDXC), voltage window.
    pub const ocr_ready: u32 = 0xC0FF_8000;
    /// The CID fill dev uses, "RA8D" packed, kept so a log reads the same.
    pub const cid_word: u32 = 0x5241_3844;
    /// CMD3 hands out RCA 1 in the top half of R6.
    pub const rca_value: u32 = 0x0001_0000;
    /// CSD structure version 2 in the top word.
    pub const csd_v2: u32 = 0x4000_0000;
};

/// The SD card state machine, as far as the identification sequence and a
/// block transfer need it.
pub const State = enum {
    idle,
    ready,
    ident,
    stby,
    tran,
};

const Block = [geometry.block_bytes]u8;

pub const Card = struct {
    allocator: std.mem.Allocator,
    blocks: std.AutoHashMap(u32, *Block),
    state: State = .idle,
    /// Blocks written that were past the end of the card.
    past_end: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Card {
        return .{
            .allocator = allocator,
            .blocks = std.AutoHashMap(u32, *Block).init(allocator),
        };
    }

    pub fn deinit(self: *Card) void {
        self.release();
        self.blocks.deinit();
    }

    /// Free every held block and put the card back in idle, which is where
    /// a power cycle leaves it.
    pub fn release(self: *Card) void {
        var it = self.blocks.valueIterator();
        while (it.next()) |block| self.allocator.destroy(block.*);
        self.blocks.clearRetainingCapacity();
        self.state = .idle;
        self.past_end = 0;
    }

    /// Blocks currently holding data. A run that only read the card holds
    /// none.
    pub fn held(self: *const Card) u32 {
        return self.blocks.count();
    }

    pub fn holds(lba: u32) bool {
        return lba < geometry.capacity_blocks;
    }

    /// A block command is only legal from the transfer state, which is
    /// where CMD7 leaves a selected card.
    pub fn canTransfer(self: *const Card) bool {
        return self.state == .tran;
    }

    /// One block out of the card. A block nobody wrote reads as zeros.
    pub fn read(self: *Card, lba: u32, out: *Block) bool {
        @memset(out, 0);
        if (!holds(lba)) {
            self.past_end += 1;
            return false;
        }
        if (self.blocks.get(lba)) |block| out.* = block.*;
        return true;
    }

    /// One block into the card, held from here on.
    pub fn write(self: *Card, lba: u32, data: *const Block) bool {
        if (!holds(lba)) {
            self.past_end += 1;
            return false;
        }
        const entry = self.blocks.getOrPut(lba) catch return false;
        if (!entry.found_existing) {
            entry.value_ptr.* = self.allocator.create(Block) catch {
                _ = self.blocks.remove(lba);
                return false;
            };
        }
        entry.value_ptr.*.* = data.*;
        return true;
    }

    /// CMD0: back to idle from wherever the card was.
    pub fn goIdle(self: *Card) void {
        self.state = .idle;
    }

    /// ACMD41 with the busy bit answered: the card has finished powering up.
    pub fn powerUp(self: *Card) void {
        if (self.state == .idle) self.state = .ready;
    }

    /// CMD2: the card publishes its CID and moves to identification.
    pub fn publishCid(self: *Card) bool {
        if (self.state != .ready) return false;
        self.state = .ident;
        return true;
    }

    /// CMD3: the card takes a relative address and stands by.
    pub fn takeAddress(self: *Card) bool {
        if (self.state != .ident) return false;
        self.state = .stby;
        return true;
    }

    /// CMD7 with this card's RCA selects it; with any other address it
    /// deselects, which is how a multi-card bus works.
    pub fn select(self: *Card, rca: u16) void {
        const mine: u16 = @intCast(response.rca_value >> 16);
        self.state = if (rca == mine) .tran else .stby;
    }

    /// The CSD v2 response words for this card's capacity, low word first.
    pub fn csd(self: *const Card) [4]u32 {
        _ = self;
        const size = @max(geometry.capacity_blocks, geometry.csize_unit);
        const c_size = (size / geometry.csize_unit) - 1;
        return .{
            0,
            (c_size & 0xFFFF) << 16,
            (c_size >> 16) & 0x3F,
            response.csd_v2,
        };
    }
};
